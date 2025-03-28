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
TARBALL_NAME="${SENSOR_TARBALL_NAME:-${SENSOR_NAME}-latest.tar.gz}"
SERVICE_NAME="${SENSOR_SERVICE_NAME:-${SENSOR_NAME}.service}"
ENV_PATH="${SENSOR_ENV_PATH:-${ENV_DIR}/env.conf}"
USER_CONFIG_PATH="${SENSOR_USER_CONFIG_PATH:-${ENV_DIR}/overrides.yaml}"
RELEASE_URL_PREFIX="${SENSOR_RELEASE_URL_PREFIX:-https://groundcover.com/artifacts/latest/groundcover-sensor}"

GO_MAX_PROCS="${SENSOR_GO_MAX_PROCS:-2}"
GO_MEMORY_LIMIT="${SENSOR_GO_MEMORY_LIMIT:-2048MiB}"
MAX_MEMORY_LIMIT="${SENSOR_MAX_MEMORY_LIMIT:-4G}"

REQUIRED_VARS=("API_KEY" "GC_ENV_NAME" "GC_DOMAIN")

set -e

usage() {
    echo "Usage: $0 [install|uninstall]"
    echo "  install   - Install or update the sensor"
    echo "  uninstall - Remove the sensor and all its configurations"
    exit 1
}

checkRootPrivileges() {
    if [[ $EUID -ne 0 ]]; then
       log_error "This script must be run with sudo or as root" 
       exit 1
    fi
    log_info "Running with root privileges"
}

validateEnvVars() {
    log_info "Validating required environment variables"
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
    echo "GOMEMORYLIMIT=${GO_MEMORY_LIMIT}" >> "${ENV_PATH}"

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
    checkConnectivity
    downloadRelease
    prepareSetup
    installSensor
    startService
}

uninstall() {
    printBanner
    uninstallSensor
}

main() {
    checkRootPrivileges
    
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
