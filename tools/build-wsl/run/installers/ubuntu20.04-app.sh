#!/bin/bash
set -euo pipefail

# ---- Variables ----

DISTRO_NAME="Ubuntu 20.04 App Build Dependencies"
PKG_DIR="$(cd "$(dirname "$0")/packages" && pwd)"
PKG_EXT="deb"

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
        dpkg-deb -f "$f" '  ${Package} ${Version}\n' 2>/dev/null
    done
    echo ""
    echo "Total: ${count} packages"
}

install_packages() {
    echo "============================================"
    echo "  ${DISTRO_NAME} - Installing"
    echo "============================================"
    echo ""
    cd "$PKG_DIR"
    dpkg -i --force-depends *."$PKG_EXT" || true
    dpkg --configure -a || true
}

uninstall_packages() {
    echo "============================================"
    echo "  ${DISTRO_NAME} - Uninstalling"
    echo "============================================"
    echo ""
    local names
    names=$(for f in "$PKG_DIR"/*."$PKG_EXT"; do dpkg-deb -f "$f" Package 2>/dev/null; done | sort -u)
    if [ -z "$names" ]; then
        echo "No packages found to uninstall."
        return
    fi
    local count
    count=$(echo "$names" | wc -l)
    echo "Removing ${count} packages..."
    echo ""
    echo "$names" | xargs dpkg --purge --force-depends 2>&1 | grep -v "not installed\|unable to remove" || true
    echo ""
    echo "Uninstall complete."
}

post_install() {
    echo ""
    echo "=== Installation Complete ==="
    gcc --version | head -1
    cmake --version | head -1
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
