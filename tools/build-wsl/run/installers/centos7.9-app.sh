#!/bin/bash
set -euo pipefail

# ---- Variables ----

DISTRO_NAME="CentOS 7.9 App Build Dependencies"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="${SCRIPT_DIR}/packages"
PKG_EXT="rpm"
STATE_FILE="/var/lib/centos7.9-app-deps-pre-install.list"

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
    rpm -qa --queryformat '%{NAME}\n' | sort -u > "$STATE_FILE"
    rpm -Uvh --nodeps --force --nodigest --nosignature "$PKG_DIR"/*."$PKG_EXT" || true
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
    echo "Removing ${count} RPM packages..."
    echo ""
    echo "$to_remove" | xargs yum remove -y 2>&1 | tail -5 || true
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
    
    # Clean up orphaned dependencies
    echo "Cleaning up orphaned dependencies..."
    yum makecache -y >/dev/null 2>&1 || true
    yum autoremove -y 2>&1 | tail -5 || true
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
