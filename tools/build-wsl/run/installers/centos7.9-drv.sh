#!/bin/bash
set -euo pipefail

# ---- Variables ----

DISTRO_NAME="CentOS 7.9 Driver Build Dependencies"
PKG_DIR="$(cd "$(dirname "$0")/packages" && pwd)"
PKG_EXT="rpm"
STATE_FILE="/var/lib/centos7.9-drv-deps-pre-install.list"

# ---- Functions ----

usage() {
    cat <<EOF
Usage: $(basename "$0") [ACTION] [OPTIONS]

Actions:
  install    Install packages (default)
  uninstall  Remove installed packages
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
        rpm -qp --queryformat '  %{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' "$f" 2>/dev/null
    done
    echo ""
    echo "Total: ${count} packages"
}

install_packages() {
    local force="${1:-false}"

    echo "============================================"
    echo "  ${DISTRO_NAME} - Installing"
    echo "============================================"
    echo ""
    rpm -qa --queryformat '%{NAME}\n' | sort -u > "$STATE_FILE"

    if [ "$force" = "true" ]; then
        rpm -Uvh --nodeps --force --nodigest --nosignature "$PKG_DIR"/*."$PKG_EXT" || true
    else
        local files_to_install=()
        local skipped=0
        for pkg_file in "$PKG_DIR"/*."$PKG_EXT"; do
            [ -f "$pkg_file" ] || continue
            local pkg_name file_ver installed_ver
            pkg_name=$(rpm -qp --queryformat '%{NAME}' "$pkg_file" 2>/dev/null)
            file_ver=$(rpm -qp --queryformat '%{VERSION}-%{RELEASE}' "$pkg_file" 2>/dev/null)
            installed_ver=$(rpm -q --queryformat '%{VERSION}-%{RELEASE}' "$pkg_name" 2>/dev/null)
            if [ $? -eq 0 ] && [ "$(printf '%s\n%s\n' "$installed_ver" "$file_ver" | sort -V | tail -1)" = "$installed_ver" ]; then
                skipped=$((skipped + 1))
                continue
            fi
            files_to_install+=("$pkg_file")
        done

        if [ ${#files_to_install[@]} -gt 0 ]; then
            echo "Installing ${#files_to_install[@]} packages (skipped $skipped up-to-date)..."
            rpm -Uvh --nodeps --nodigest --nosignature "${files_to_install[@]}" || true
        else
            echo "All packages are up-to-date (skipped $skipped)."
        fi
    fi
}

uninstall_packages() {
    echo "============================================"
    echo "  ${DISTRO_NAME} - Uninstalling"
    echo "============================================"
    echo ""
    
    # Read package list from packages.list (only top-level packages, not dependencies)
    local packages_list_file="$(cd "$(dirname "$0")" && pwd)/packages.list"
    if [ ! -f "$packages_list_file" ]; then
        echo "No packages.list found, cannot determine which packages to remove."
        return
    fi
    
    local names
    names=$(cat "$packages_list_file" | sort -u)
    if [ -z "$names" ]; then
        echo "No packages found to uninstall."
        return
    fi
    
    local to_remove="$names"
    if [ -f "$STATE_FILE" ]; then
        # Only remove packages that were NOT pre-installed
        to_remove=$(comm -23 <(echo "$names") <(sort "$STATE_FILE"))
        rm -f "$STATE_FILE"
    fi
    
    if [ -z "$to_remove" ]; then
        echo "No new packages to remove (all were pre-installed)."
        return
    fi
    
    local count
    count=$(echo "$to_remove" | wc -l)
    echo "Removing ${count} packages..."
    echo ""
    echo "$to_remove" | xargs yum remove -y 2>&1 | tail -5 || true
    echo ""
    
    # Clean up orphaned dependencies
    echo "Cleaning up orphaned dependencies..."
    yum makecache -y >/dev/null 2>&1 || true
    yum autoremove -y 2>&1 | tail -5 || true
    echo ""
    
    echo "Uninstall complete."
}

post_install() {
    echo ""
    echo "=== Installation Complete ==="
    KVER=$(uname -r)
    echo "Running kernel: $KVER"
    if [ -d "/usr/src/kernels/${KVER}" ]; then
        echo "kernel-devel matched: /usr/src/kernels/${KVER}"
    else
        echo "WARNING: kernel-devel version may not match running kernel."
        echo "Available: $(ls /usr/src/kernels/ 2>/dev/null || echo 'none')"
    fi
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
    install)
        install_packages "$FORCE"
        post_install
        ;;
    uninstall)  uninstall_packages ;;
    list)       list_packages ;;
    help)       usage ;;
    *)
        echo "Unknown action: $ACTION"
        usage
        exit 1
        ;;
esac
