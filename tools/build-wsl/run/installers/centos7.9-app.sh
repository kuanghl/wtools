#!/bin/bash
set -euo pipefail

# ---- Variables ----

DISTRO_NAME="CentOS 7.9 App Build Dependencies"
INSTALLER_ID="centos7.9-app"
PKG_EXT="rpm"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="${SCRIPT_DIR}/packages"
INSTALLED_FILE="/var/lib/${INSTALLER_ID}-installed.list"

# ---- Package manager functions (RPM/Yum) ----

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
    if [ -d "$SCRIPT_DIR/extra" ] && [ -f "$SCRIPT_DIR/extra/.extra-manifest" ]; then
        echo ""
        echo "  Extra bundles:"
        while IFS= read -r rel_path; do
            count=$((count + 1))
            echo "    /${rel_path}/"
        done < "$SCRIPT_DIR/extra/.extra-manifest"
    fi
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

    # Snapshot pre-install state
    local pre_tmp post_tmp
    pre_tmp=$(mktemp)
    post_tmp=$(mktemp)
    pkg_list_installed | sort -u > "$pre_tmp"

    # Install packages
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

    # Snapshot post-install state and compute diff (includes all dependencies)
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

    # Install extra bundles
    if [ -d "$SCRIPT_DIR/extra" ] && [ -f "$SCRIPT_DIR/extra/.extra-manifest" ]; then
        echo ""
        echo "Installing extra bundles..."
        while IFS= read -r rel_path; do
            local tar_name parent_dir
            tar_name="$(basename "$rel_path").tar.gz"
            parent_dir="/$(dirname "$rel_path")"
            mkdir -p "$parent_dir"
            echo "  Extracting $tar_name to $parent_dir"
            tar xzf "$SCRIPT_DIR/extra/$tar_name" -C "$parent_dir"
        done < "$SCRIPT_DIR/extra/.extra-manifest"
        ln -sf /opt/cmake/bin/cmake /usr/bin/cmake
        ln -sf /opt/cmake/bin/ctest /usr/bin/ctest
        ln -sf /opt/cmake/bin/cpack /usr/bin/cpack
    fi

    # Post-install
    local bashrc_line="source /opt/rh/devtoolset-9/enable"
    if ! grep -qF "$bashrc_line" /etc/bashrc 2>/dev/null; then
        echo "$bashrc_line" >> /etc/bashrc
    fi
    echo ""
    echo "=== Installation Complete ==="
    bash -lc "gcc --version | head -1"
    echo "devtoolset-9 enabled in /etc/bashrc (new sessions auto-activate)"
    echo "For current session: source /opt/rh/devtoolset-9/enable"
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

    # Remove extra bundles
    if [ -d "$SCRIPT_DIR/extra" ] && [ -f "$SCRIPT_DIR/extra/.extra-manifest" ]; then
        echo ""
        echo "Removing extra bundles..."
        while IFS= read -r rel_path; do
            echo "  Removing /${rel_path}/"
            rm -rf "/${rel_path}"
        done < "$SCRIPT_DIR/extra/.extra-manifest"
        rm -f /usr/bin/cmake /usr/bin/ctest /usr/bin/cpack
    fi

    # Clean up orphaned dependencies
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
