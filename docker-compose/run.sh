#!/bin/sh
set -eu

if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != --edge ]; }; then
    echo "Usage: $0 [--edge]" >&2
    exit 1
fi
edge=${1:-}
: "${SENSOR_VERSION:?set the pinned sensor version}"
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SENSOR_DIR=$(CDPATH= cd -- "${SENSOR_DIR:-/data/groundcover}" && pwd)
export SENSOR_DIR

if docker compose version >/dev/null 2>&1; then
    set -- docker compose
elif command -v docker-compose >/dev/null 2>&1; then
    set -- docker-compose
else
    echo "Docker Compose is required" >&2
    exit 1
fi

if [ "$edge" = --edge ]; then
    env_file="$SENSOR_DIR/env.conf"
    if [ ! -f "$env_file" ]; then
        echo "Prepare $env_file first; see README.md" >&2
        exit 1
    fi
    sed -i '/^GC_ENVTYPE=/d' "$env_file"
    printf '\nGC_ENVTYPE=edge\n' >> "$env_file"
fi

exec "$@" -p groundcover -f "$script_dir/compose.yaml" up -d --force-recreate groundcover-sensor
