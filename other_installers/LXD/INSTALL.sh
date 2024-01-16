#!/bin/bash

setVars() {
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    RED='\033[0;31m'
    NC='\033[0m' # No Color

    STORAGE_POOL_NAME=$(generateName "AIL")
    NETWORK_NAME=$(generateName "AIL")
    NETWORK_NAME=${NETWORK_NAME:0:14}
    PROFILE=$(generateName "AIL")

    UBUNTU="ubuntu:22.04"
}

setDefaults(){
    default_ail_project=$(generateName "AIL")
    default_ail_name=$(generateName "AIL")
    default_lacus="Yes"
    default_lacus_name=$(generateName "LACUS")
}

error() {
    echo -e "${RED}ERROR: $1${NC}"
}

warn() {
    echo -e "${YELLOW}WARNING: $1${NC}"
}

info() {
    echo -e "${BLUE}INFO: $1${NC}"
}

success() {
    echo -e "${GREEN}SUCCESS: $1${NC}"
}

err() {
    local parent_lineno="$1"
    local message="$2"
    local code="${3:-1}"

    if [[ -n "$message" ]] ; then
        error "Line ${parent_lineno}: ${message}: exiting with status ${code}"
    else
        error "Line ${parent_lineno}: exiting with status ${code}"
    fi

    deleteLXDProject "$PROJECT_NAME"
    lxc storage delete "$APP_STORAGE"
    lxc storage delete "$DB_STORAGE"
    lxc network delete "$NETWORK_NAME"
    exit "${code}"
}

generateName(){
    local name="$1"
    echo "${name}-$(date +%Y%m%d%H%M%S)"
}

setupLXD(){
    lxc project create "$PROJECT_NAME"
    lxc project switch "$PROJECT_NAME"

    if checkRessourceExist "storage" "$STORAGE_POOL_NAME"; then
        error "Storage '$STORAGE_POOL_NAME' already exists."
        exit 1
    fi
    lxc storage create "$STORAGE_POOL_NAME" zfs source="$PARTITION_NAME"

    if checkRessourceExist "network" "$NETWORK_NAME"; then
        error "Network '$NETWORK_NAME' already exists."
    fi
    lxc network create "$NETWORK_NAME" --type=bridge

    if checkRessourceExist "profile" "$PROFILE"; then
        error "Profile '$PROFILE' already exists."
    fi
    lxc profile create "$PROFILE"
    lxc profile device add "$PROFILE" root disk path="/" pool="$STORAGE_POOL_NAME"
    lxc profile device add "$PROFILE" eth0 nic name=eth0 network="$NETWORK_NAME"
}

waitForContainer() {
    local container_name="$1"

    sleep 3
    while true; do
        status=$(lxc list --format=json | jq -e --arg name "$container_name"  '.[] | select(.name == $name) | .status')
        if [ "$status" = "\"Running\"" ]; then
            echo -e "${BLUE}$container_name ${GREEN}is running.${NC}"
            break
        fi
        echo "Waiting for $container_name container to start."
        sleep 5
    done
}

interrupt() {
    warn "Script interrupted by user. Delete project and exit ..."
    deleteLXDProject "$PROJECT_NAME"
    lxc network delete "$NETWORK_NAME"
    exit 130
}

deleteLXDProject(){
    local project="$1"

    echo "Starting cleanup ..."
    echo "Deleting container in project"
    for container in $(lxc query "/1.0/containers?recursion=1&project=${project}" | jq .[].name -r); do
        lxc delete --project "${project}" -f "${container}"
    done

    echo "Deleting images in project"
    for image in $(lxc query "/1.0/images?recursion=1&project=${project}" | jq .[].fingerprint -r); do
        lxc image delete --project "${project}" "${image}"
    done

    echo "Deleting profiles in project"
    for profile in $(lxc query "/1.0/profiles?recursion=1&project=${project}" | jq .[].name -r); do
    if [ "${profile}" = "default" ]; then
        printf 'config: {}\ndevices: {}' | lxc profile edit --project "${project}" default
        continue
    fi
    lxc profile delete --project "${project}" "${profile}"
    done

    echo "Deleting project"
    lxc project delete "${project}"
}

createAILContainer(){
    lxc launch $UBUNTU "$AIL_CONTAINER" --profile "$PROFILE"
    waitForContainer "$AIL_CONTAINER"
    lxc exec "$AIL_CONTAINER" -- sed -i "/#\$nrconf{restart} = 'i';/s/.*/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf
    lxc exec "$AIL_CONTAINER" -- apt update
    lxc exec "$AIL_CONTAINER" -- apt upgrade -y
    lxc exec "$AIL_CONTAINER" -- useradd -m -s /bin/bash ail
    if lxc exec "$AIL_CONTAINER" -- id ail; then
        lxc exec "$AIL_CONTAINER" -- usermod -aG sudo ail
        success "User ail created."
    else
        error "User ail not created."
        exit 1
    fi
    lxc exec "$AIL_CONTAINER" -- bash -c "echo 'ail ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/ail"
    lxc exec "$AIL_CONTAINER" --cwd=/home/ail -- sudo -u ail bash -c "git clone https://github.com/ail-project/ail-framework.git"
    lxc exec "$AIL_CONTAINER" --cwd=/home/ail/ail-framework -- sudo -u ail bash -c "./installing_deps.sh"
    lxc exec "$AIL_CONTAINER" -- sed -i '/^\[Flask\]/,/^\[/ s/host = 127\.0\.0\.1/host = 0.0.0.0/' /home/ail/ail-framework/configs/core.cfg
    lxc exec "$AIL_CONTAINER" --cwd=/home/ail/ail-framework/bin -- sudo -u ail bash -c "./LAUNCH.sh -l"
    lxc exec "$AIL_CONTAINER" -- sed -i "/^\$nrconf{restart} = 'a';/s/.*/#\$nrconf{restart} = 'i';/" /etc/needrestart/needrestart.conf
}

createLacusContainer(){
    lxc launch $UBUNTU "$LACUS_CONTAINER" --profile "$PROFILE"
    waitForContainer "$LACUS_CONTAINER"
    lxc exec "$LACUS_CONTAINER" -- sed -i "/#\$nrconf{restart} = 'i';/s/.*/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf
    lxc exec "$LACUS_CONTAINER" -- apt update
    lxc exec "$LACUS_CONTAINER" -- apt upgrade -y
    lxc exec "$LACUS_CONTAINER" -- apt install pipx -y
    lxc exec "$LACUS_CONTAINER" -- pipx install poetry 
    lxc exec "$LACUS_CONTAINER" -- pipx ensurepath
    lxc exec "$LACUS_CONTAINER" -- apt install build-essential tcl -y
    lxc exec "$LACUS_CONTAINER" -- git clone https://github.com/redis/redis.git
    lxc exec "$LACUS_CONTAINER" --cwd=/root/redis -- git checkout 7.2
    lxc exec "$LACUS_CONTAINER" --cwd=/root/redis -- make
    lxc exec "$LACUS_CONTAINER" --cwd=/root/redis -- make test
    lxc exec "$LACUS_CONTAINER" -- git clone https://github.com/ail-project/lacus.git
    lxc exec "$LACUS_CONTAINER" --cwd=/root/lacus -- /root/.local/bin/poetry install
    AIL_VENV_PATH=$(lxc exec "$LACUS_CONTAINER" --cwd=/root/lacus -- bash -c "/root/.local/bin/poetry env info -p")
    # lxc exec "$LACUS_CONTAINER" --cwd=/root/lacus -- bash -c "source ${AIL_VENV_PATH}/bin/activate"
    # lxc exec "$LACUS_CONTAINER" --cwd=/root/lacus -- /root/.local/bin/poetry shell
    lxc exec "$LACUS_CONTAINER" --cwd=/root/lacus -- bash -c "source ${AIL_VENV_PATH}/bin/activate && playwright install-deps"
    lxc exec "$LACUS_CONTAINER" --cwd=/root/lacus -- bash -c "echo LACUS_HOME=/root/lacus >> .env"
    lxc exec "$LACUS_CONTAINER" --cwd=/root/lacus -- bash -c "export PATH='/root/.local/bin:$PATH' && yes | /root/.local/bin/poetry run update --init"
    lxc exec "$LACUS_CONTAINER" -- sed -i "/^\$nrconf{restart} = 'a';/s/.*/#\$nrconf{restart} = 'i';/" /etc/needrestart/needrestart.conf
}

nonInteractiveConfig(){
    VALID_ARGS=$(getopt -o h --long help,production,project:ail-name:,no-lacus,lacus-name:  -- "$@")
    if [[ $? -ne 0 ]]; then
        exit 1;
    fi

    eval set -- "$VALID_ARGS"
    while [ $# -gt 0 ]; do
        case "$1" in
            -h | --help)
                usage
                exit 0
                ;;
            --project)
                ail_project=$2
                shift 2
                ;;
            --ail-name)
                ail_name=$2
                shift 2
                ;;
            --no-lacus)
                lacus="N"
                shift
                ;;
            --lacus-name)
                lacus_name=$2
                shift 2
                ;;
            *)  
                break 
                ;;
        esac
    done

    # Set global values
    PROJECT_NAME=${ail_project:-$default_ail_project}
    AIL_CONTAINER=${ail_name:-$default_ail_name}
    lacus=${lacus:-$default_lacus}
    LACUS=$(echo "$lacus" | grep -iE '^y(es)?$' > /dev/null && echo true || echo false)
    LACUS_CONTAINER=${lacus_name:-$default_lacus_name}
}

validateArgs(){
    # Check Names
    local names=("$PROJECT_NAME" "$AIL_CONTAINER")
    for i in "${names[@]}"; do
        if ! checkNamingConvention "$i"; then
            exit 1
        fi
    done

    if $LACUS && ! checkNamingConvention "$LACUS_CONTAINER"; then
        exit 1
    fi

    # Check for Project
    if checkRessourceExist "project" "$PROJECT_NAME"; then
        error "Project '$PROJECT_NAME' already exists."
        exit 1
    fi

    # Check Container Names
    local containers=("$AIL_CONTAINER")

    declare -A name_counts
    for name in "${containers[@]}"; do
    ((name_counts["$name"]++))
    done

    if $LACUS;then
        ((name_counts["$LACUS_CONTAINER"]++))
    fi

    for name in "${!name_counts[@]}"; do
    if ((name_counts["$name"] >= 2)); then
        error "At least two container have the same name: $name"
        exit 1
    fi
    done
}

checkRessourceExist() {
    local resource_type="$1"
    local resource_name="$2"

    case "$resource_type" in
        "container")
            lxc info "$resource_name" &>/dev/null
            ;;
        "image")
            lxc image list --format=json | jq -e --arg alias "$resource_name" '.[] | select(.aliases[].name == $alias) | .fingerprint' &>/dev/null
            ;;
        "project")
            lxc project list --format=json | jq -e --arg name "$resource_name" '.[] | select(.name == $name) | .name' &>/dev/null
            ;;
        "storage")
            lxc storage list --format=json | jq -e --arg name "$resource_name" '.[] | select(.name == $name) | .name' &>/dev/null
            ;;
        "network")
            lxc network list --format=json | jq -e --arg name "$resource_name" '.[] | select(.name == $name) | .name' &>/dev/null
            ;;
        "profile")
            lxc profile list --format=json | jq -e --arg name "$resource_name" '.[] | select(.name == $name) | .name' &>/dev/null
            ;;
    esac

    return $?
}

checkNamingConvention(){
    local input="$1"
    local pattern="^[a-zA-Z0-9-]+$"

    if ! [[ "$input" =~ $pattern ]]; then
        error "Invalid Name $input. Please use only alphanumeric characters and hyphens."
        return 1
    fi
    return 0
}

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  -h, --help                  Display this help message and exit."
    echo "  --project <project_name>    Specify the project name."
    echo "  --ail-name <container_name> Specify the AIL container name."
    echo "  --no-lacus                  Do not create Lacus container."
    echo "  --lacus-name <container_name> Specify the Lacus container name."
    echo "  -i, --interactive           Run the script in interactive mode."
    echo
    echo "This script sets up LXD containers for AIL and optionally Lacus."
    echo "It creates a new LXD project, and configures the network and storage."
    echo "Then it launches and configures the specified containers."
    echo
    echo "Examples:"
    echo "  $0 --project myProject --ail-name ailContainer"
    echo "  $0 --interactive"
}

# ------------------ MAIN ------------------

setDefaults

# Check if interactive mode
INTERACTIVE=false
for arg in "$@"; do
    if [[ $arg == "-i" ]] || [[ $arg == "--interactive" ]]; then
        INTERACTIVE=true
        break
    fi
done

if [ "$INTERACTIVE" = true ]; then
    interactiveConfig
else
    nonInteractiveConfig "$@"
fi

validateArgs
setVars

trap 'interrupt' INT
trap 'err ${LINENO}' ERR

info "Setup LXD Project"
setupLXD

info "Create AIL Container"
createAILContainer

if $LACUS; then
    info "Create Lacus Container"
    createLacusContainer
fi

# Print info
ail_ip=$(lxc list $AIL_CONTAINER --format=json | jq -r '.[0].state.network.eth0.addresses[] | select(.family=="inet").address')
if $LACUS; then
    lacus_ip=$(lxc list $LACUS_CONTAINER --format=json | jq -r '.[0].state.network.eth0.addresses[] | select(.family=="inet").address')
fi
ail_email=$(lxc exec $AIL_CONTAINER -- bash -c "grep '^email=' /home/ail/ail-framework/DEFAULT_PASSWORD | cut -d'=' -f2")
ail_password=$(lxc exec $AIL_CONTAINER -- bash -c "grep '^password=' /home/ail/ail-framework/DEFAULT_PASSWORD | cut -d'=' -f2")
ail_API_Key=$(lxc exec $AIL_CONTAINER -- bash -c "grep '^API_Key=' /home/ail/ail-framework/DEFAULT_PASSWORD | cut -d'=' -f2")

echo "--------------------------------------------------------------------------------------------"
echo -e "${BLUE}AIL ${NC}is up and running on $ail_ip"
echo "--------------------------------------------------------------------------------------------"
echo -e "${BLUE}AIL ${NC}credentials:"
echo -e "Email: ${GREEN}$ail_email${NC}"
echo -e "Password: ${GREEN}$ail_password${NC}"
echo -e "API Key: ${GREEN}$ail_API_Key${NC}"
echo "--------------------------------------------------------------------------------------------"
if $LACUS; then
    echo -e "${BLUE}Lacus ${NC}is up and running on $lacus_ip"
fi
echo "--------------------------------------------------------------------------------------------"
