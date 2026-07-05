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

if [[ -t 1 ]]; then
    BOLD="$(tput bold 2>/dev/null || printf '')"
    GREY="$(tput setaf 0 2>/dev/null || printf '')"
    RED="$(tput setaf 1 2>/dev/null || printf '')"
    GREEN="$(tput setaf 2 2>/dev/null || printf '')"
    NO_COLOR="$(tput sgr0 2>/dev/null || printf '')"
else
    BOLD='' GREY='' RED='' GREEN='' NO_COLOR=''
fi

log_info() {
    printf '%s\n' "${BOLD}${GREY}>${NO_COLOR} $*"
}

log_error() {
    printf '%s\n' "${RED}✕ $*${NO_COLOR}" >&2
}

log_success() {
   printf '%s\n' "${GREEN}✔${NO_COLOR} $*"
}

die() {
    log_error "$*"
    exit 1
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
LOCK_FILE="${SENSOR_LOCK_FILE:-/run/${SENSOR_NAME}-install.lock}"

GO_MAX_PROCS="${SENSOR_GO_MAX_PROCS:-2}"
GO_MEMORY_LIMIT="${SENSOR_GO_MEMORY_LIMIT:-2048MiB}"
MAX_MEMORY_LIMIT="${SENSOR_MAX_MEMORY_LIMIT:-4G}"

REQUIRED_VARS=("API_KEY" "GC_ENV_NAME" "GC_DOMAIN")

set -Eeuo pipefail
trap 'log_error "Failed unexpectedly at line ${LINENO}: ${BASH_COMMAND}"' ERR

usage() {
    cat << EOF
Usage: install.sh [install|uninstall]

Commands:
  install     Install or update the sensor
  uninstall   Stop the sensor and remove all its files and configurations

Required environment variables for install:
  API_KEY      groundcover ingestion API key
  GC_ENV_NAME  Environment name the sensor reports as
  GC_DOMAIN    groundcover backend domain to send data to

Optional overrides:
  SENSOR_INSTALL_DIR       Install location (default: /opt/groundcover)
  SENSOR_ENV_DIR           Configuration location (default: /etc/opt/groundcover)
  SENSOR_GO_MAX_PROCS      Sensor GOMAXPROCS (default: ${GO_MAX_PROCS})
  SENSOR_GO_MEMORY_LIMIT   Sensor GOMEMORYLIMIT (default: ${GO_MEMORY_LIMIT})
  SENSOR_MAX_MEMORY_LIMIT  systemd MemoryMax (default: ${MAX_MEMORY_LIMIT})
EOF
    exit "${1:-1}"
}

checkPlatform() {
    local os
    os=$(uname -s)
    if [[ "${os}" != "Linux" ]]; then
        die "The groundcover sensor only supports Linux (detected: ${os})"
    fi
}

checkRootPrivileges() {
    if [[ $EUID -ne 0 ]]; then
       die "This script must be run with sudo or as root"
    fi
    log_info "Running with root privileges"
}

requireCommands() {
    local cmd
    for cmd in "$@"; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            die "Required command '${cmd}' not found"
        fi
    done
}

acquireLock() {
    exec 9> "${LOCK_FILE}"
    if ! flock -n 9; then
        die "Another sensor install/uninstall is already running"
    fi
}

validateEnvVars() {
    log_info "Validating required environment variables"
    for var in "${REQUIRED_VARS[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            die "Environment variable $var must be set"
        fi
    done
    log_success "All required environment variables are set"
}

httpGet() {
    local fail_msg="$1" hint="$2"
    shift 2

    local http_code rc=0
    http_code=$(curl -sS -w "%{http_code}" --connect-timeout 10 "$@") || rc=$?

    if [[ ${rc} -ne 0 ]]; then
        die "${fail_msg} (curl exit code ${rc})${hint}"
    fi

    if [[ "${http_code}" != "200" ]]; then
        die "${fail_msg} (HTTP ${http_code})${hint}"
    fi
}

checkConnectivity() {
    log_info "Checking connectivity to groundcover backend"

    httpGet "Failed to connect to groundcover backend" ", please check your API key and contact support if the issue persists" \
        --retry 2 --max-time 30 -o /dev/null -H "apikey: ${API_KEY}" "https://${GC_DOMAIN}/health/live"

    log_success "Successfully verified connectivity to groundcover backend"
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
            die "Unsupported architecture: ${arch}"
            ;;
    esac

    local download_url="${RELEASE_URL_PREFIX}-${tarball_arch}"
    log_info "Downloading release from: ${download_url}"

    WORK_DIR=$(mktemp -d)
    trap 'rm -rf "${WORK_DIR}"' EXIT
    TARBALL_PATH="${WORK_DIR}/${TARBALL_NAME}"

    httpGet "Failed to download release package" "" \
        -L --retry 3 --max-time 600 -o "${TARBALL_PATH}" "${download_url}"

    log_success "Successfully downloaded release package"
}

prepareSensorConfig() {
    local config_path="${1}"

    if [[ ! -f "${config_path}" ]]; then
        die "Configuration file '${config_path}' not found"
    fi

    local placeholder_list
    placeholder_list=$(grep -oE '<GC_PLACEHOLDER_[A-Z0-9_]+>' "${config_path}" | sort -u || true)

    if [[ -z "${placeholder_list}" ]]; then
        return 0
    fi

    local content placeholder env_var_name
    content=$(< "${config_path}")

    while IFS= read -r placeholder; do
        env_var_name="${placeholder#<GC_PLACEHOLDER_}"
        env_var_name="GC_${env_var_name%>}"

        if [[ -z "${!env_var_name:-}" ]]; then
            die "Environment variable '${env_var_name}' not set"
        fi

        content=${content//"${placeholder}"/${!env_var_name}}
    done <<< "${placeholder_list}"

    printf '%s\n' "${content}" > "${config_path}"
}

prepareSetup() {
    log_info "Extracting sensor package"

    STAGING_DIR="${WORK_DIR}/package"
    mkdir -p "${STAGING_DIR}"
    tar -xzf "${TARBALL_PATH}" -C "${STAGING_DIR}"

    if [[ ! -f "${STAGING_DIR}/${SENSOR_NAME}" ]]; then
        die "Executable binary ${SENSOR_NAME} not found in package"
    fi
    chmod +x "${STAGING_DIR}/${SENSOR_NAME}"

    log_info "Preparing sensor configuration"
    prepareSensorConfig "${STAGING_DIR}/config/config.yaml"
    prepareSensorConfig "${STAGING_DIR}/${SCRAPE_CONFIG_DIR}/logs-scrape-config.yaml"
    prepareSensorConfig "${STAGING_DIR}/${SCRAPE_CONFIG_DIR}/metrics-scrape-config.yaml"

    log_success "Sensor package prepared"
}

deploySensorFiles() {
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        log_info "Stopping running sensor service before upgrade"
        systemctl stop "${SERVICE_NAME}"
    fi

    log_info "Installing sensor package to ${INSTALL_DIR}"
    rm -rf "${INSTALL_DIR}"
    mkdir -p "${INSTALL_DIR}"
    cp -a "${STAGING_DIR}/." "${INSTALL_DIR}/"

    BINARY_PATH="${INSTALL_DIR}/${SENSOR_NAME}"
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
    cat > "${ENV_PATH}" << EOL
API_KEY=${API_KEY}
CONFIG_OVERRIDES_PATH=${USER_CONFIG_PATH}
FLORA_PROMETHEUSSERVER_ENABLED=false
FLORA_CONTAINERREPOSITORY_TRACKEDCONTAINERTYPE=docker
GOMAXPROCS=${GO_MAX_PROCS}
GOMEMORYLIMIT=${GO_MEMORY_LIMIT}
EOL

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

    if ! systemctl start "${SERVICE_NAME}"; then
        log_error "Service failed to start. Recent logs:"
        journalctl -u "${SERVICE_NAME}" --no-pager -n 50 || true
        exit 1
    fi

    sleep 2

    if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
        log_error "groundcover sensor failed to stay running. Recent logs:"
        journalctl -u "${SERVICE_NAME}" --no-pager -n 50 || true
        exit 1
    fi

    log_success "groundcover sensor is up and running"
    log_info "To check sensor status: systemctl status ${SERVICE_NAME}"
    log_info "To view sensor logs: journalctl -u ${SERVICE_NAME}"
}

removePath() {
    local path="$1" description="$2"

    if [[ -e "${path}" ]]; then
        log_info "Removing ${description}"
        rm -rfv "${path}"
    fi
}

uninstallSensor() {
    log_info "Starting uninstallation process"

    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        log_info "Stopping sensor service"
        systemctl stop "${SERVICE_NAME}"
    fi

    if systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null; then
        log_info "Disabling sensor service"
        systemctl disable "${SERVICE_NAME}"
    fi

    systemctl reset-failed "${SERVICE_NAME}" 2>/dev/null || true

    removePath "/etc/systemd/system/${SERVICE_NAME}" "service file"
    systemctl daemon-reload

    removePath "${INSTALL_DIR}" "installation directory"
    removePath "${ENV_DIR}" "environment configuration directory"

    log_success "Uninstallation completed successfully"
}

install() {
    validateEnvVars
    printBanner
    checkConnectivity
    downloadRelease
    prepareSetup
    deploySensorFiles
    installSensor
    startService
}

uninstall() {
    printBanner
    uninstallSensor
}

main() {
    case "${1:-}" in
        install|uninstall)
            checkPlatform
            checkRootPrivileges
            requireCommands curl tar systemctl journalctl mktemp flock
            acquireLock
            "$1"
            ;;
        -h|--help|help)
            usage 0
            ;;
        *)
            usage 1
            ;;
    esac
}

main "$@"
