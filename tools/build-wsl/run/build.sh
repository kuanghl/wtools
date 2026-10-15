#!/bin/bash
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_WORK_DIR=""
cleanup() { [ -n "$BUILD_WORK_DIR" ] && rm -rf "$BUILD_WORK_DIR"; }
trap cleanup EXIT

build_run() {
    local installer="$1"
    local pkg_dir="$2"
    local output_name="$3"
    local display_name="$4"
    local work_dir="$5"
    local extra_dirs=("${@:6}")

    local staging="${work_dir}/staging-$(basename "$output_name" .run)"
    mkdir -p "$staging/packages"
    cp "$installer" "$staging/install.sh"
    cp "$pkg_dir"/* "$staging/packages/" 2>/dev/null || true

    # Create package list file for uninstall (only top-level packages, not dependencies)
    if [ -f "${installer%.sh}-packages.list" ]; then
        cp "${installer%.sh}-packages.list" "$staging/packages.list"
    fi

    if [ ${#extra_dirs[@]} -gt 0 ]; then
        mkdir -p "$staging/extra"
        for dir in "${extra_dirs[@]}"; do
            local name
            name=$(basename "$dir")
            tar czf "$staging/extra/${name}.tar.gz" -C "$(dirname "$dir")" "$name"
            echo "  Bundled extra: ${dir}"
        done
    fi

    local run_file="${work_dir}/${output_name}"

    cat > "$run_file" << HEADER
#!/bin/bash
# ${display_name} - Offline Installer
# Usage: sudo ./\$(basename "\$0") [install|uninstall|list]

set -euo pipefail

if [ "\$(id -u)" -ne 0 ]; then
    echo "ERROR: Please run as root: sudo ./\$(basename "\$0") [install|uninstall|list]"
    exit 1
fi

echo "Extracting ${display_name}..."
SKIP=\$(awk '/^__PAYLOAD_BELOW__\$/{print NR; exit}' "\$0")
TMPDIR=\$(mktemp -d /tmp/${output_name}.XXXXXX)
trap '/usr/bin/rm -rf "\$TMPDIR"' EXIT
tail -n +\$((SKIP + 1)) "\$0" | tar xz -C "\$TMPDIR"

bash "\$TMPDIR/install.sh" "\$@"
exit \$?

__PAYLOAD_BELOW__
HEADER

    tar czf - -C "$staging" . >> "$run_file"
    chmod +x "$run_file"

    local size
    size=$(du -h "$run_file" | cut -f1)
    echo "Created ${output_name} (${size})"
}

main() {
    local config_file="${1:?Usage: $0 <config-file>}"
    source "$config_file"

    local build_id="${DISTRO_ID}-$(date +%Y%m%d%H%M%S)-$$"
    mkdir -p "${SCRIPT_ROOT}/output"
    BUILD_WORK_DIR=$(mktemp -d "${SCRIPT_ROOT}/output/.build-${build_id}.XXXXXX")
    local work_dir="$BUILD_WORK_DIR"

    echo "=== Building ${DISTRO_NAME} offline packages [${build_id}] ==="

    local app_pkg_dir="${work_dir}/app-packages"
    local drv_pkg_dir="${work_dir}/drv-packages"
    mkdir -p "$app_pkg_dir" "$drv_pkg_dir"

    echo "--- Downloading app packages ---"
    download_packages "$app_pkg_dir" "${APP_PACKAGES[@]}"
    echo "App packages: $(ls "$app_pkg_dir"/*."$PKG_EXT" 2>/dev/null | wc -l) ${PKG_EXT^^}s"
    
    # Generate app packages list for uninstall
    printf '%s\n' "${APP_PACKAGES[@]}" > "${SCRIPT_ROOT}/installers/${DISTRO_ID}-app-packages.list"

    echo "--- Downloading drv packages ---"
    download_packages "$drv_pkg_dir" "${DRV_PACKAGES[@]}"
    echo "Drv packages: $(ls "$drv_pkg_dir"/*."$PKG_EXT" 2>/dev/null | wc -l) ${PKG_EXT^^}s"
    
    # Generate drv packages list for uninstall
    printf '%s\n' "${DRV_PACKAGES[@]}" > "${SCRIPT_ROOT}/installers/${DISTRO_ID}-drv-packages.list"

    echo "--- Generating installers ---"
    build_run "${SCRIPT_ROOT}/installers/${DISTRO_ID}-app.sh" \
        "$app_pkg_dir" "${DISTRO_ID}-app-deps.run" "${DISTRO_NAME} App Build Dependencies" \
        "$work_dir" ${APP_EXTRA_TARS[@]+"${APP_EXTRA_TARS[@]}"}
    build_run "${SCRIPT_ROOT}/installers/${DISTRO_ID}-drv.sh" \
        "$drv_pkg_dir" "${DISTRO_ID}-drv-deps.run" "${DISTRO_NAME} Driver Build Dependencies" \
        "$work_dir" ${DRV_EXTRA_TARS[@]+"${DRV_EXTRA_TARS[@]}"}

    mv "$work_dir"/*.run "${SCRIPT_ROOT}/output/"

    echo "=== ${DISTRO_NAME} build complete [${build_id}] ==="
    ls -lh "${SCRIPT_ROOT}/output/${DISTRO_ID}"-*.run
}

main "$@"
