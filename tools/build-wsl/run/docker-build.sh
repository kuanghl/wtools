#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="${SCRIPT_DIR}/../docker"

declare -A BASE_IMAGES=(
    [centos7.9]=semp-centos7
    [centos8.5]=semp-centos8.5
    [ubuntu20.04]=semp-ubuntu20.04
)

build_base() {
    local distro="$1"
    local image="${BASE_IMAGES[$distro]}"
    echo "=== Building base image: ${image} ==="
    docker build -t "$image" -f "${DOCKER_DIR}/Dockerfile.${distro}" "${DOCKER_DIR}"
}

build_all() {
    local distro="$1"
    local image="${BASE_IMAGES[$distro]}.all"
    echo "=== Building all-deps image: ${image} ==="
    docker build -t "$image" -f "${DOCKER_DIR}/Dockerfile.${distro}.all" "${DOCKER_DIR}"
}

run_build() {
    local distro="$1"
    local config="$2"
    local image="${BASE_IMAGES[$distro]}.all"
    echo "=== Running build in: ${image} ==="
    docker run --rm \
        -v "${SCRIPT_DIR}:${SCRIPT_DIR}" \
        -w "${SCRIPT_DIR}" \
        "$image" \
        bash ./build.sh "$config"
}

main() {
    local distro="${1:?Usage: $0 <centos7.9|centos8.5|ubuntu20.04> [config-path]}"
    local config="${2:-config/${distro}.conf}"

    build_base "$distro"
    build_all "$distro"
    run_build "$distro" "$config"
}

main "$@"
