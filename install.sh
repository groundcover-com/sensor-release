#!/usr/bin/env bash

# Copyright The groundcover Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

BOLD="$(tput bold 2>/dev/null || printf '')"
GREY="$(tput setaf 0 2>/dev/null || printf '')"
RED="$(tput setaf 1 2>/dev/null || printf '')"
GREEN="$(tput setaf 2 2>/dev/null || printf '')"
NO_COLOR="$(tput sgr0 2>/dev/null || printf '')"

log_info() {
    printf '%s\n' "${BOLD}${GREY}>${NO_COLOR} $*"
}

log_error() {
    printf '%s\n' "${RED}✕ $*${NO_COLOR}" >&2
}

log_success() {
   printf '%s\n' "${GREEN}✔${NO_COLOR} $*"
}

printBanner() {
cat << 'BANNER'
                                   _
    __ _ _ __ ___  _   _ _ __   __| | ___ _____   _____ _ __
   / _` | '__/ _ \| | | | '_ \ / _` |/ __/ _ \ \ / / _ \ '__|
  | (_| | | | (_) | |_| | | | | (_| | (_| (_) \ V /  __/ |
   \__, |_|  \___/ \__,_|_| |_|\__,_|\___\___/ \_/ \___|_|
   |___/                                       
         #NO TRADE-OFFS

BANNER
}

INSTALL_DIR="${SENSOR_INSTALL_DIR:-/opt/groundcover}"
SCRAPE_CONFIG_DIR="scrape-config"
ENV_DIR="${SENSOR_ENV_DIR:-/etc/opt/groundcover}"
SENSOR_NAME="${SENSOR_NAME:-groundcover-sensor}"
SENSOR_VERSION="${SENSOR_VERSION:-latest}"
TARBALL_NAME="${SENSOR_TARBALL_NAME:-${SENSOR_NAME}-latest.tar.gz}"
SERVICE_NAME="${SENSOR_SERVICE_NAME:-${SENSOR_NAME}.service}"
ENV_PATH="${SENSOR_ENV_PATH:-${ENV_DIR}/env.conf}"
USER_CONFIG_PATH="${SENSOR_USER_CONFIG_PATH:-${ENV_DIR}/overrides.yaml}"
RELEASE_URL_PREFIX="${SENSOR_RELEASE_URL_PREFIX:-https://groundcover.com/artifacts/latest/groundcover-sensor}"

INSTALL_MODE="${SENSOR_INSTALL_MODE:-systemd}"
DOCKER_DATA_DIR="${SENSOR_DOCKER_DATA_DIR:-/data/groundcover}"
IMAGE_REPOSITORY="${SENSOR_IMAGE_REPOSITORY:-public.ecr.aws/groundcovercom/sensor}"
RELIABLE_JOURNAL_DELIVERY="${SENSOR_RELIABLE_JOURNAL_DELIVERY:-}"
HEALTH_URL="http://127.0.0.1:2021/health"

GO_MAX_PROCS="${SENSOR_GO_MAX_PROCS:-2}"
GO_MEMORY_LIMIT="${SENSOR_GO_MEMORY_LIMIT:-2048MiB}"
MAX_MEMORY_LIMIT="${SENSOR_MAX_MEMORY_LIMIT:-4G}"

REQUIRED_VARS=("API_KEY" "GC_ENV_NAME" "GC_DOMAIN")

set -e

usage() {
    echo "Usage: $0 [install|uninstall]"
    echo "  install   - Install or update the sensor"
    echo "  uninstall - Remove the sensor and all its configurations"
    echo ""
    echo "Set SENSOR_VERSION to a release version (e.g. 1.12.383) to install it instead of latest."
    echo "Set SENSOR_INSTALL_MODE=docker to run the sensor as a container instead of a systemd service;"
    echo "it keeps its configuration and state under SENSOR_DOCKER_DATA_DIR (default /data/groundcover)."
    echo "In Docker mode, SENSOR_RELIABLE_JOURNAL_DELIVERY=true resends journal logs written while offline;"
    echo "the choice is kept for later installs. Lines you add to the data directory's env.conf are kept too."
    exit 1
}

checkRootPrivileges() {
    if [[ $EUID -ne 0 ]]; then
       log_error "This script must be run with sudo or as root" 
       exit 1
    fi
    log_info "Running with root privileges"
}

validateInstallMode() {
    if [[ "${INSTALL_MODE}" != "systemd" && "${INSTALL_MODE}" != "docker" ]]; then
        log_error "SENSOR_INSTALL_MODE must be 'systemd' or 'docker'"
        exit 1
    fi
    if [[ -n "${RELIABLE_JOURNAL_DELIVERY}" && "${RELIABLE_JOURNAL_DELIVERY}" != "true" && "${RELIABLE_JOURNAL_DELIVERY}" != "false" ]]; then
        log_error "SENSOR_RELIABLE_JOURNAL_DELIVERY must be 'true' or 'false'"
        exit 1
    fi
}

validateEnvVars() {
    log_info "Validating required environment variables"
    if [[ "${SENSOR_VERSION}" != "latest" ]]; then
        if [[ ! "${SENSOR_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            log_error "SENSOR_VERSION must be 'latest' or a version in X.Y.Z format (e.g. 1.12.383)"
            exit 1
        fi
        if [[ -n "${SENSOR_RELEASE_URL_PREFIX:-}" ]]; then
            log_error "SENSOR_VERSION cannot be combined with SENSOR_RELEASE_URL_PREFIX; unset one of them"
            exit 1
        fi
    fi
    for var in "${REQUIRED_VARS[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log_error "Environment variable $var must be set"
            exit 1
        fi
    done
    log_success "All required environment variables are set"
}

checkCurl() {
    if ! command -v curl >/dev/null 2>&1; then
        log_error "curl not found"
        exit 1
    fi
}

downloadRelease() {
    log_info "Detecting system architecture"
    local arch
    arch=$(uname -m)
    local tarball_arch

    case "${arch}" in
        x86_64)
            tarball_arch="amd64"
            ;;
        aarch64)
            tarball_arch="arm64"
            ;;
        *)
            log_error "Unsupported architecture: ${arch}"
            exit 1
            ;;
    esac

    local download_url="${RELEASE_URL_PREFIX}-${tarball_arch}"
    if [[ "${SENSOR_VERSION}" != "latest" ]]; then
        download_url="https://github.com/groundcover-com/sensor-release/releases/download/release/sensor/${SENSOR_VERSION}/groundcover-sensor-${tarball_arch}.tar.gz"
    fi
    log_info "Downloading release from: ${download_url}"
    
    checkCurl
    
    http_code=$(curl -s -w "%{http_code}" -L -o "${TARBALL_NAME}" "${download_url}")

    if [[ "${http_code}" != "200" ]]; then
        rm -f "${TARBALL_NAME}"
        log_error "Failed to download release package"
        exit 1
    fi

    log_success "Successfully downloaded release package"
}

prepareSensorConfig() {
    local config_path="${1}"

    log_info "Preparing sensor configuration"

    if [[ ! -f "${config_path}" ]]; then
        log_error "Configuration file '${config_path}' not found"
        exit 1
    fi

    local placeholder_list
    placeholder_list=$(grep -oE '<GC_PLACEHOLDER_[A-Z0-9_]+>' "${config_path}" | sort -u)

    if [[ -z "$placeholder_list" ]]; then
        log_info "No placeholders found in configuration"
        return 0
    fi

    while IFS= read -r placeholder; do
        local env_var_name
        env_var_name=$(echo "$placeholder" | sed -E 's/^<GC_PLACEHOLDER_(.*)>$/GC_\1/')

        if [[ -n "${!env_var_name:-}" ]]; then
            sed -i "s|${placeholder}|${!env_var_name}|g" "${config_path}"
        else
            log_error "Environment variable '$env_var_name' not set"
            exit 1
        fi
    done <<< "$placeholder_list"

    log_success "Configuration setup completed successfully"
    return 0
}

prepareSetup() {
    local CONFIG_PATH="${INSTALL_DIR}/config/config.yaml"
    local LOGS_SCRAPE_CONFIG_PATH="${INSTALL_DIR}/${SCRAPE_CONFIG_DIR}/logs-scrape-config.yaml"
    local METRICS_SCRAPE_CONFIG_PATH="${INSTALL_DIR}/${SCRAPE_CONFIG_DIR}/metrics-scrape-config.yaml"

    log_info "Starting sensor package setup"

    if [[ ! -f "${TARBALL_NAME}" ]]; then
        log_error "Tarball ${TARBALL_NAME} not found in the current directory"
        exit 1
    fi

    log_info "Creating installation directory: ${INSTALL_DIR}"
    mkdir -p "${INSTALL_DIR}"

    log_info "Extracting sensor package"
    tar -xzf "${TARBALL_NAME}" -C "${INSTALL_DIR}"

    BINARY_PATH="${INSTALL_DIR}/${SENSOR_NAME}"
    if [[ ! -x "${BINARY_PATH}" ]]; then
        log_error "Executable binary ${SENSOR_NAME} not found"
        exit 1
    fi

    log_info "Setting permissions for installation directory"
    chmod +x "${BINARY_PATH}"

    prepareSensorConfig "${CONFIG_PATH}"
    prepareSensorConfig "${LOGS_SCRAPE_CONFIG_PATH}"
    prepareSensorConfig "${METRICS_SCRAPE_CONFIG_PATH}"
}

setupServiceEnv() {
    log_info "Setting up service environment"

    log_info "Creating environment directory: ${ENV_DIR}"
    mkdir -p "${ENV_DIR}"

    log_info "Creating environment configuration file"
    : > "${ENV_PATH}"
    chmod 600 "${ENV_PATH}"

    if [[ ! -f "$USER_CONFIG_PATH" ]]; then
        cat > "${USER_CONFIG_PATH}" << EOL
# Overrides Configuration File
EOL

    chmod 600 "${USER_CONFIG_PATH}"
    fi

    log_info "Writing environment variables"
    echo "API_KEY=$API_KEY" >> "${ENV_PATH}"
    echo "CONFIG_OVERRIDES_PATH=${USER_CONFIG_PATH}" >> "${ENV_PATH}"
    echo "FLORA_PROMETHEUSSERVER_ENABLED=false" >> "${ENV_PATH}"
    echo "FLORA_CONTAINERREPOSITORY_TRACKEDCONTAINERTYPE=docker" >> "${ENV_PATH}"
    echo "GOMAXPROCS=${GO_MAX_PROCS}" >> "${ENV_PATH}"
    echo "GOMEMLIMIT=${GO_MEMORY_LIMIT}" >> "${ENV_PATH}"

    log_success "Environment configuration completed"
}

installSensor() {
    log_info "Creating systemd service file"
    cat > "/etc/systemd/system/${SERVICE_NAME}" << EOL
[Unit]
Description=${SENSOR_NAME} Sensor Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
Environment="HOSTNAME=%H"
EnvironmentFile=${ENV_PATH}
ExecStart=${BINARY_PATH}
MemoryMax=${MAX_MEMORY_LIMIT}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOL
    
    setupServiceEnv
    log_success "Sensor service configuration completed"
}

startService() {
    log_info "Starting groundcover sensor service"
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}"

    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        log_info "Stopping existing service"
        systemctl stop "${SERVICE_NAME}"
    fi
    
    if ! systemctl start "${SERVICE_NAME}"; then
        log_error "Service failed to start. Recent logs:"
        journalctl -u "${SERVICE_NAME}" --no-pager -n 50
        exit 1
    fi

    log_success "groundcover sensor service installation complete!"

    systemctl is-active --quiet "${SERVICE_NAME}" && 
        log_success "groundcover sensor is up and running" || 
        log_error "groundcover sensor failed to start"

    log_info "To check sensor status: systemctl status ${SERVICE_NAME}"
    log_info "To view sensor logs: journalctl -u ${SERVICE_NAME}"
}

uninstallSensor() {
    log_info "Starting uninstallation process"

    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        log_info "Stopping sensor service"
        systemctl stop "${SERVICE_NAME}"
    fi
    
    if systemctl is-enabled --quiet "${SERVICE_NAME}"; then
        log_info "Disabling sensor service"
        systemctl disable "${SERVICE_NAME}"
    fi

    if [[ -f "/etc/systemd/system/${SERVICE_NAME}" ]]; then
        log_info "Removing service file"
        rm -fv "/etc/systemd/system/${SERVICE_NAME}"
        systemctl daemon-reload
    fi

    if [[ -d "${INSTALL_DIR}" ]]; then
        log_info "Removing installation directory"
        rm -rfv "${INSTALL_DIR}"
    fi

    log_success "Uninstallation completed successfully"

}

checkDocker() {
    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        log_error "Docker installation requires a running Docker daemon"
        exit 1
    fi
}

resolveLatestVersion() {
    # The image is published per release only, so `latest` becomes the newest release tag.
    local latest_url
    latest_url=$(curl -s -o /dev/null -w "%{redirect_url}" "https://github.com/groundcover-com/sensor-release/releases/latest")
    SENSOR_VERSION="${latest_url##*/}"
    if [[ ! "${SENSOR_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Failed to resolve the latest sensor version; set SENSOR_VERSION"
        exit 1
    fi
    log_info "Latest sensor version: ${SENSOR_VERSION}"
}

prepareDockerSetup() {
    # Download into the data directory: the working directory may be read-only.
    TARBALL_NAME="${DOCKER_DATA_DIR}/${TARBALL_NAME##*/}"

    log_info "Preparing sensor data directory: ${DOCKER_DATA_DIR}"
    if ! mkdir -p "${DOCKER_DATA_DIR}/state/positions" "${DOCKER_DATA_DIR}/state/vmagent_pq"; then
        log_error "Cannot write ${DOCKER_DATA_DIR}; set SENSOR_DOCKER_DATA_DIR to a writable, persistent directory"
        exit 1
    fi

    downloadRelease
    log_info "Extracting sensor configuration"
    if ! tar -xzf "${TARBALL_NAME}" -C "${DOCKER_DATA_DIR}" config "${SCRAPE_CONFIG_DIR}"; then
        rm -f "${TARBALL_NAME}"
        log_error "Failed to extract sensor configuration"
        exit 1
    fi
    rm -f "${TARBALL_NAME}"

    prepareSensorConfig "${DOCKER_DATA_DIR}/config/config.yaml"
    prepareSensorConfig "${DOCKER_DATA_DIR}/${SCRAPE_CONFIG_DIR}/logs-scrape-config.yaml"
    prepareSensorConfig "${DOCKER_DATA_DIR}/${SCRAPE_CONFIG_DIR}/metrics-scrape-config.yaml"

    # The package ships a positions file relative to its working directory,
    # which is the container's read-only root.
    sed -i 's|^\([[:space:]]*positionsFile:\).*|\1 /var/run/positions/positions.yaml|' "${DOCKER_DATA_DIR}/config/config.yaml"

    # Choices from an earlier install stay unless this install sets them again.
    local settings="${DOCKER_DATA_DIR}/installer.conf"
    if [[ -z "${RELIABLE_JOURNAL_DELIVERY}" && -f "${settings}" ]]; then
        RELIABLE_JOURNAL_DELIVERY=$(sed -n 's/^SENSOR_RELIABLE_JOURNAL_DELIVERY=//p' "${settings}")
    fi
    RELIABLE_JOURNAL_DELIVERY="${RELIABLE_JOURNAL_DELIVERY:-false}"
    echo "SENSOR_RELIABLE_JOURNAL_DELIVERY=${RELIABLE_JOURNAL_DELIVERY}" > "${settings}"
    # Written into config.yaml: the sensor may ignore an environment variable for a key the release config lacks.
    if [[ "${RELIABLE_JOURNAL_DELIVERY}" == "true" ]]; then
        awk '{ print } /^[[:space:]]*journalConfig:[[:space:]]*$/ { match($0, /^ */); pad = substr($0, 1, RLENGTH); print pad "  reliableDelivery:"; print pad "    enabled: true" }' \
            "${DOCKER_DATA_DIR}/config/config.yaml" > "${DOCKER_DATA_DIR}/config/config.yaml.tmp" \
            && mv "${DOCKER_DATA_DIR}/config/config.yaml.tmp" "${DOCKER_DATA_DIR}/config/config.yaml"
    fi

    if [[ ! -f "${DOCKER_DATA_DIR}/config/overrides.yaml" ]]; then
        echo "# Overrides Configuration File" > "${DOCKER_DATA_DIR}/config/overrides.yaml"
    fi

    local env_path="${DOCKER_DATA_DIR}/env.conf"
    local managed='^(API_KEY|CONFIG_OVERRIDES_PATH|FLORA_EBPFENABLED|FLORA_PROMETHEUSSERVER_ENABLED|FLORA_CONTAINERREPOSITORY_TRACKEDCONTAINERTYPE|FLORA_SYSTEMINFO_HOSTMOUNTPATH|GOMAXPROCS|GOMEMLIMIT)='
    local customer=""
    if [[ -f "${env_path}" ]]; then
        customer=$(grep -Ev "${managed}" "${env_path}" || true)
    fi
    : > "${env_path}"
    chmod 600 "${env_path}"
    {
        echo "API_KEY=${API_KEY}"
        echo "CONFIG_OVERRIDES_PATH=/config/overrides.yaml"
        echo "FLORA_EBPFENABLED=false"
        echo "FLORA_PROMETHEUSSERVER_ENABLED=false"
        echo "FLORA_CONTAINERREPOSITORY_TRACKEDCONTAINERTYPE=docker"
        echo "FLORA_SYSTEMINFO_HOSTMOUNTPATH=/host"
        echo "GOMAXPROCS=${GO_MAX_PROCS}"
        echo "GOMEMLIMIT=${GO_MEMORY_LIMIT}"
        if [[ -n "${customer}" ]]; then
            printf '%s\n' "${customer}"
        fi
    } >> "${env_path}"
}

startDockerSensor() {
    local image="${IMAGE_REPOSITORY}:${SENSOR_VERSION}"
    local mounts=(
        -v "${DOCKER_DATA_DIR}/config:/config:ro"
        -v "${DOCKER_DATA_DIR}/${SCRAPE_CONFIG_DIR}:/${SCRAPE_CONFIG_DIR}:ro"
        -v "${DOCKER_DATA_DIR}/state/positions:/var/run/positions"
        -v "${DOCKER_DATA_DIR}/state/vmagent_pq:/vmagent_pq"
        -v "/:/host:ro"
    )
    # The sensor reads these at fixed paths, with no host prefix.
    local path
    for path in /var/log/journal /run/log/journal /etc/machine-id /var/run/docker.sock; do
        if [[ -e "${path}" ]]; then
            mounts+=(-v "${path}:${path}:ro")
        fi
    done

    # main runs under `||`, which disables `set -e`, so each docker step checks itself.
    log_info "Pulling sensor image ${image}"
    if ! docker pull "${image}" >/dev/null; then
        log_error "Failed to pull sensor image ${image}"
        exit 1
    fi

    if docker inspect "${SENSOR_NAME}" >/dev/null 2>&1; then
        log_info "Replacing existing sensor container"
        docker rm -f "${SENSOR_NAME}" >/dev/null
    fi

    log_info "Starting sensor container"
    # NET_ADMIN lets flora read per-process CPU and disk delay through the kernel's taskstats interface.
    if ! docker run -d --name "${SENSOR_NAME}" --restart unless-stopped \
        --read-only --tmpfs /tmp --network host --cap-add NET_ADMIN \
        --memory "${MAX_MEMORY_LIMIT}" \
        --env-file "${DOCKER_DATA_DIR}/env.conf" -e "HOSTNAME=$(hostname)" \
        "${mounts[@]}" "${image}" >/dev/null; then
        log_error "Failed to start sensor container"
        exit 1
    fi

    local attempt
    for attempt in $(seq 1 60); do
        if curl -fsS --max-time 2 "${HEALTH_URL}" >/dev/null 2>&1; then
            log_success "groundcover sensor is up and running"
            log_info "To view sensor logs: docker logs ${SENSOR_NAME}"
            return 0
        fi
        sleep 2
    done

    log_error "Sensor did not become healthy. Recent logs:"
    docker logs --tail 50 "${SENSOR_NAME}"
    exit 1
}

uninstallDockerSensor() {
    log_info "Starting uninstallation process"
    if docker inspect "${SENSOR_NAME}" >/dev/null 2>&1; then
        log_info "Removing sensor container"
        docker rm -f "${SENSOR_NAME}" >/dev/null
    fi
    log_success "Uninstallation completed; data kept in ${DOCKER_DATA_DIR}"
}

checkConnectivity() {
    log_info "Checking connectivity to groundcover backend"
    local health_url="https://${GC_DOMAIN}/health/live"
    
    checkCurl

    local http_code
    http_code=$(curl -s -w "%{http_code}" -o /dev/null -H "apikey: ${API_KEY}" "${health_url}")
    
    if [[ "${http_code}" != "200" ]]; then
        log_error "Failed to connect to groundcover backend (HTTP ${http_code}), please check your API key and contact support if the issue persists"
        exit 1
    fi

    log_success "Successfully verified connectivity to groundcover backend"
}

install() {
    validateEnvVars
    printBanner
    if [[ "${INSTALL_MODE}" == "docker" ]]; then
        checkDocker
        checkConnectivity
        if [[ "${SENSOR_VERSION}" == "latest" ]]; then
            resolveLatestVersion
        fi
        prepareDockerSetup
        startDockerSensor
        return
    fi
    checkConnectivity
    downloadRelease
    prepareSetup
    installSensor
    startService
}

uninstall() {
    printBanner
    if [[ "${INSTALL_MODE}" == "docker" ]]; then
        checkDocker
        uninstallDockerSensor
        return
    fi
    uninstallSensor
}

main() {
    checkRootPrivileges
    validateInstallMode

    case "$1" in
        "install")
            install
            ;;
        "uninstall")
            uninstall
            ;;
        *)
            usage
            ;;
    esac

}

main "$@" || exit 1
