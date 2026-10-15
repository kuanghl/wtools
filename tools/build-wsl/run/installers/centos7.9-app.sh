#!/bin/bash
set -euo pipefail

# ---- Variables ----

DISTRO_NAME="CentOS 7.9 App Build Dependencies"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="${SCRIPT_DIR}/packages"
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
    if [ -d "$SCRIPT_DIR/extra" ]; then
        echo ""
        echo "  Extra bundles:"
        for t in "$SCRIPT_DIR"/extra/*.tar.gz; do
            [ -f "$t" ] || continue
            count=$((count + 1))
            echo "    $(basename "$t" .tar.gz)/"
        done
    fi
    echo ""
    echo "Total: ${count} items"
}

install_packages() {
    echo "============================================"
    echo "  ${DISTRO_NAME} - Installing"
    echo "============================================"
    echo ""
    rpm -Uvh --nodeps "$PKG_DIR"/*."$PKG_EXT" || true
    rpm -Uvh --force "$PKG_DIR"/*."$PKG_EXT" || true
    if [ -d "$SCRIPT_DIR/extra" ]; then
        echo ""
        echo "Installing extra bundles..."
        for t in "$SCRIPT_DIR"/extra/*.tar.gz; do
            [ -f "$t" ] || continue
            echo "  Extracting $(basename "$t") to /"
            tar xzf "$t" -C /
        done
        ln -sf /opt/cmake/bin/cmake /usr/bin/cmake
        ln -sf /opt/cmake/bin/ctest /usr/bin/ctest
        ln -sf /opt/cmake/bin/cpack /usr/bin/cpack
    fi
}

uninstall_packages() {
    echo "============================================"
    echo "  ${DISTRO_NAME} - Uninstalling"
    echo "============================================"
    echo ""
    local names
    names=$(rpm -qp --queryformat '%{NAME}\n' "$PKG_DIR"/*."$PKG_EXT" 2>/dev/null | sort -u)
    if [ -n "$names" ]; then
        local count
        count=$(echo "$names" | wc -l)
        echo "Removing ${count} RPM packages..."
        echo ""
        echo "$names" | xargs rpm -e --nodeps 2>&1 | grep -v "not installed" || true
    fi
    if [ -d "$SCRIPT_DIR/extra" ]; then
        echo ""
        echo "Removing extra bundles..."
        for t in "$SCRIPT_DIR"/extra/*.tar.gz; do
            [ -f "$t" ] || continue
            local name
            name=$(basename "$t" .tar.gz)
            echo "  Removing /${name}/"
            rm -rf "/${name}"
        done
        rm -f /usr/bin/cmake /usr/bin/ctest /usr/bin/cpack
    fi
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
