#!/bin/bash
set -euo pipefail

# ---- Variables ----

DISTRO_NAME="Ubuntu 20.04 Driver Build Dependencies"
PKG_DIR="$(cd "$(dirname "$0")/packages" && pwd)"
PKG_EXT="deb"
STATE_FILE="/var/lib/ubuntu20.04-drv-deps-pre-install.list"

# ---- Functions ----

usage() {
    cat <<EOF
Usage: $(basename "$0") [ACTION]

Actions:
  install    Install packages (default)
  uninstall  Remove installed packages
  list       List bundled packages
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
        local pkg ver
        pkg=$(dpkg-deb --field "$f" Package 2>/dev/null)
        ver=$(dpkg-deb --field "$f" Version 2>/dev/null)
        echo "  ${pkg} ${ver}"
    done
    echo ""
    echo "Total: ${count} packages"
}

install_packages() {
    echo "============================================"
    echo "  ${DISTRO_NAME} - Installing"
    echo "============================================"
    echo ""
    dpkg-query -W -f '${Package}\n' > "$STATE_FILE"
    cd "$PKG_DIR"
    dpkg -i *."$PKG_EXT" || true
    dpkg --configure -a || true
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
    echo "$to_remove" | xargs apt-get purge -y 2>&1 | tail -5 || true
    echo ""
    
    # Clean up orphaned dependencies
    echo "Cleaning up orphaned dependencies..."
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get autoremove -y 2>&1 | tail -5 || true
    echo ""
    
    echo "Uninstall complete."
}

post_install() {
    echo ""
    echo "=== Installation Complete ==="
    KVER=$(uname -r)
    echo "Running kernel: $KVER"
    if ls /usr/src/linux-headers-*${KVER}* -d 2>/dev/null; then
        echo "linux-headers matched"
    else
        echo "WARNING: linux-headers version may not match running kernel."
        echo "Available: $(ls /usr/src/ | grep linux-headers || echo 'none')"
    fi
}

# ---- Main ----

action="${1:-install}"
case "$action" in
    install)
        install_packages
        post_install
        ;;
    uninstall)  uninstall_packages ;;
    list)       list_packages ;;
    -h|--help)  usage ;;
    *)
        echo "Unknown action: $action"
        usage
        exit 1
        ;;
esac
