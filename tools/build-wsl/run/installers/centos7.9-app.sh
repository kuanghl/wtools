#!/bin/bash
set -euo pipefail

# ---- Variables ----

DISTRO_NAME="CentOS 7.9 App Build Dependencies"
PKG_DIR="$(cd "$(dirname "$0")/packages" && pwd)"
PKG_EXT="rpm"

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
        rpm -qp --queryformat '  %{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' "$f" 2>/dev/null
    done
    echo ""
    echo "Total: ${count} packages"
}

install_packages() {
    echo "============================================"
    echo "  ${DISTRO_NAME} - Installing"
    echo "============================================"
    echo ""
    rpm -Uvh --nodeps "$PKG_DIR"/*."$PKG_EXT" || true
    rpm -Uvh --force "$PKG_DIR"/*."$PKG_EXT" || true
}

uninstall_packages() {
    echo "============================================"
    echo "  ${DISTRO_NAME} - Uninstalling"
    echo "============================================"
    echo ""
    local names
    names=$(rpm -qp --queryformat '%{NAME}\n' "$PKG_DIR"/*."$PKG_EXT" 2>/dev/null | sort -u)
    if [ -z "$names" ]; then
        echo "No packages found to uninstall."
        return
    fi
    local count
    count=$(echo "$names" | wc -l)
    echo "Removing ${count} packages..."
    echo ""
    echo "$names" | xargs rpm -e --nodeps 2>&1 | grep -v "not installed" || true
    echo ""
    echo "Uninstall complete."
}

post_install() {
    echo "source /opt/rh/devtoolset-9/enable" >> /etc/bashrc
    echo ""
    echo "=== Installation Complete ==="
    bash -lc "gcc --version | head -1"
    echo "devtoolset-9 enabled in /etc/bashrc (new sessions auto-activate)"
    echo "For current session: source /opt/rh/devtoolset-9/enable"
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
