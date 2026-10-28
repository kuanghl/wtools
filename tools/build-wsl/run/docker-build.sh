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
    if [ $force -eq 0 ] && docker image inspect "$image" >/dev/null 2>&1; then
        echo "=== Base image '${image}' already exists, skipping build ==="
        return
    fi
    echo "=== Building base image: ${image} ==="
    docker build -t "$image" -f "${DOCKER_DIR}/Dockerfile.${distro}" "${DOCKER_DIR}"
}

build_all() {
    local distro="$1"
    local image="${BASE_IMAGES[$distro]}.all"
    if [ $force -eq 0 ] && docker image inspect "$image" >/dev/null 2>&1; then
        echo "=== All-deps image '${image}' already exists, skipping build ==="
        return
    fi
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
    local force=0
    local args=()
    for arg in "$@"; do
        case "$arg" in
            --force) force=1 ;;
            *) args+=("$arg") ;;
        esac
    done

    local distro="${args[0]:?Usage: $0 [--force] <centos7.9|centos8.5|ubuntu20.04> [config-path]}"
    local config="${args[1]:-config/${distro}.conf}"

    [ $force -eq 1 ] && echo "Force rebuild enabled."

    build_base "$distro"
    build_all "$distro"
    run_build "$distro" "$config"
}

main "$@"
