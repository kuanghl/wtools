#!/bin/bash
set -euo pipefail

# ---- Variables ----

DISTRO_NAME="Ubuntu 20.04 App Build Dependencies"
PKG_DIR="$(cd "$(dirname "$0")/packages" && pwd)"
PKG_EXT="deb"
STATE_FILE="/var/lib/ubuntu20.04-app-deps-pre-install.list"

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
        local pkg ver
        pkg=$(dpkg-deb --field "$f" Package 2>/dev/null)
        ver=$(dpkg-deb --field "$f" Version 2>/dev/null)
        echo "  ${pkg} ${ver}"
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
    dpkg-query -W -f '${Package}\n' > "$STATE_FILE"

    if [ "$force" = "true" ]; then
        dpkg -i "$PKG_DIR"/*."$PKG_EXT" || true
        dpkg --configure -a || true
    else
        local files_to_install=()
        local skipped=0
        for pkg_file in "$PKG_DIR"/*."$PKG_EXT"; do
            [ -f "$pkg_file" ] || continue
            local pkg_name file_ver installed_ver
            pkg_name=$(dpkg-deb --field "$pkg_file" Package 2>/dev/null)
            file_ver=$(dpkg-deb --field "$pkg_file" Version 2>/dev/null)
            if installed_ver=$(dpkg-query -W -f '${Version}' "$pkg_name" 2>/dev/null); then
                if [ "$(printf '%s\n%s\n' "$installed_ver" "$file_ver" | sort -V | tail -1)" = "$installed_ver" ]; then
                    skipped=$((skipped + 1))
                    continue
                fi
            fi
            files_to_install+=("$pkg_file")
        done

        if [ ${#files_to_install[@]} -gt 0 ]; then
            echo "Installing ${#files_to_install[@]} packages (skipped $skipped up-to-date)..."
            dpkg -i "${files_to_install[@]}" || true
            dpkg --configure -a || true
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
    gcc --version | head -1
    cmake --version | head -1
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
