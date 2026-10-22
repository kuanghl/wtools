#!/bin/bash
set -euo pipefail

# ---- Variables ----

DISTRO_NAME="CentOS 8.5 Driver Build Dependencies"
INSTALLER_ID="centos8.5-drv"
PKG_EXT="rpm"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="${SCRIPT_DIR}/packages"
INSTALLED_FILE="/var/lib/${INSTALLER_ID}-installed.list"

# ---- Package manager functions (RPM/DNF) ----

pkg_list_installed() {
    rpm -qa --queryformat '%{NAME}\n'
}

pkg_query_name() {
    rpm -qp --queryformat '%{NAME}' "$1" 2>/dev/null
}

pkg_query_version() {
    rpm -qp --queryformat '%{VERSION}-%{RELEASE}' "$1" 2>/dev/null
}

pkg_query_installed_ver() {
    rpm -q --queryformat '%{VERSION}-%{RELEASE}' "$1" 2>/dev/null
}

pkg_format_list_entry() {
    rpm -qp --queryformat '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' "$1" 2>/dev/null
}

pkg_install_files() {
    rpm -Uvh --nodeps --force --nodigest --nosignature "$@" || true
}

pkg_remove_single() {
    rpm -e "$1" 2>/dev/null
}

pkg_autoremove() {
    yum makecache -y >/dev/null 2>&1 || true
    yum autoremove -y 2>&1 | tail -5 || true
}

# ---- Functions ----

usage() {
    cat <<EOF
Usage: $(basename "$0") [ACTION] [OPTIONS]

Actions:
  install    Install packages (default)
  uninstall  Remove installed packages (soft — skips what cannot be removed)
  list       List bundled packages

Options:
  --force    Force install all packages regardless of existing versions
EOF
}

list_packages() {
    echo "============================================"
    echo "  ${DISTRO_NAME} - Bundled Packages"
    echo "============================================"
    echo ""
    local count=0
    for f in "$PKG_DIR"/*."$PKG_EXT"; do
        [ -f "$f" ] || continue
        count=$((count + 1))
        echo "  $(pkg_format_list_entry "$f")"
    done
    echo ""
    echo "Total: ${count} items"
    echo ""
    if [ -f "$INSTALLED_FILE" ]; then
        local tracked
        tracked=$(wc -l < "$INSTALLED_FILE")
        echo "Status: installed ($tracked packages tracked)"
    else
        echo "Status: not installed"
    fi
}

install_packages() {
    local force="${1:-false}"

    echo "============================================"
    echo "  ${DISTRO_NAME} - Installing"
    echo "============================================"
    echo ""

    local pre_tmp post_tmp
    pre_tmp=$(mktemp)
    post_tmp=$(mktemp)
    pkg_list_installed | sort -u > "$pre_tmp"

    local pkg_files=("$PKG_DIR"/*."$PKG_EXT")
    if [ ! -f "${pkg_files[0]}" ]; then
        echo "No package files found in $PKG_DIR"
        rm -f "$pre_tmp" "$post_tmp"
        return 1
    fi

    if [ "$force" = "true" ]; then
        pkg_install_files "${pkg_files[@]}"
    else
        local files_to_install=()
        local skipped=0
        for pkg_file in "${pkg_files[@]}"; do
            local pkg_name file_ver installed_ver
            pkg_name=$(pkg_query_name "$pkg_file")
            file_ver=$(pkg_query_version "$pkg_file")
            if installed_ver=$(pkg_query_installed_ver "$pkg_name"); then
                if [ "$(printf '%s\n%s\n' "$installed_ver" "$file_ver" | sort -V | tail -1)" = "$installed_ver" ]; then
                    skipped=$((skipped + 1))
                    continue
                fi
            fi
            files_to_install+=("$pkg_file")
        done

        if [ ${#files_to_install[@]} -gt 0 ]; then
            echo "Installing ${#files_to_install[@]} packages (skipped $skipped up-to-date)..."
            pkg_install_files "${files_to_install[@]}"
        else
            echo "All packages are up-to-date (skipped $skipped)."
        fi
    fi

    pkg_list_installed | sort -u > "$post_tmp"
    local new_tmp
    new_tmp=$(mktemp)
    comm -13 "$pre_tmp" "$post_tmp" > "$new_tmp"
    if [ -f "$INSTALLED_FILE" ]; then
        sort -u "$INSTALLED_FILE" "$new_tmp" > "${INSTALLED_FILE}.tmp"
        mv "${INSTALLED_FILE}.tmp" "$INSTALLED_FILE"
    else
        cp "$new_tmp" "$INSTALLED_FILE"
    fi
    rm -f "$pre_tmp" "$post_tmp" "$new_tmp"

    local tracked
    tracked=$(wc -l < "$INSTALLED_FILE")
    echo ""
    echo "Tracked $tracked new packages for uninstall (including dependencies)."

    # Post-install
    echo ""
    echo "=== Installation Complete ==="
    local kver
    kver=$(uname -r)
    echo "Running kernel: $kver"
    if [ -d "/usr/src/kernels/${kver}" ]; then
        echo "kernel-devel matched: /usr/src/kernels/${kver}"
    else
        echo "WARNING: kernel-devel version may not match running kernel."
        echo "Available: $(ls /usr/src/kernels/ 2>/dev/null || echo 'none')"
    fi
}

uninstall_packages() {
    echo "============================================"
    echo "  ${DISTRO_NAME} - Uninstalling (soft)"
    echo "============================================"
    echo ""

    local removed=0 skipped_missing=0 skipped_fail=0
    local has_records=false

    if [ -f "$INSTALLED_FILE" ]; then
        has_records=true
        local total
        total=$(wc -l < "$INSTALLED_FILE")

        if [ "$total" -gt 0 ]; then
            echo "Processing $total tracked packages..."
            echo ""

            while IFS= read -r pkg_name; do
                [ -z "$pkg_name" ] && continue

                if ! pkg_query_installed_ver "$pkg_name" &>/dev/null; then
                    echo "  SKIP (not installed): $pkg_name"
                    skipped_missing=$((skipped_missing + 1))
                    continue
                fi

                if pkg_remove_single "$pkg_name"; then
                    echo "  REMOVED: $pkg_name"
                    removed=$((removed + 1))
                else
                    echo "  SKIP (cannot remove): $pkg_name"
                    skipped_fail=$((skipped_fail + 1))
                fi
            done < "$INSTALLED_FILE"
        fi

        rm -f "$INSTALLED_FILE"
    fi

    if [ "$has_records" = false ]; then
        echo "No installation record found."
    fi

    echo ""
    echo "Package summary: removed=$removed, not-installed=$skipped_missing, cannot-remove=$skipped_fail"

    echo ""
    echo "Cleaning up orphaned dependencies..."
    pkg_autoremove

    echo ""
    echo "Uninstall complete."
}

# ---- Main ----

FORCE=false
ACTION=""
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=true ;;
        install|uninstall|list) ACTION="$arg" ;;
        -h|--help) ACTION="help" ;;
        *) echo "Unknown option: $arg"; usage; exit 1 ;;
    esac
done
ACTION="${ACTION:-install}"

case "$ACTION" in
    install)    install_packages "$FORCE" ;;
    uninstall)  uninstall_packages ;;
    list)       list_packages ;;
    help)       usage ;;
    *)          echo "Unknown action: $ACTION"; usage; exit 1 ;;
esac
