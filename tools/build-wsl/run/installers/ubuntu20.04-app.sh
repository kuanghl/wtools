#!/bin/bash
set -euo pipefail

# ---- Variables ----

DISTRO_NAME="Ubuntu 20.04 App Build Dependencies"
INSTALLER_ID="ubuntu20.04-app"
EXPECTED_OS_ID="ubuntu"
EXPECTED_OS_MAJOR="20"
PKG_EXT="deb"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="${SCRIPT_DIR}/packages"
INSTALLED_FILE="/var/lib/${INSTALLER_ID}-installed.list"

# System-critical packages that should never be removed during uninstall
# This list is populated at build time from config/*.conf
PROTECTED_PACKAGES=()

is_protected_package() {
    local pkg="$1"
    for protected in "${PROTECTED_PACKAGES[@]}"; do
        if [ "$pkg" = "$protected" ]; then
            return 0
        fi
    done
    return 1
}

# ---- Package manager functions (DEB/dpkg) ----

pkg_list_installed() {
    dpkg-query -W -f '${Package}\n'
}

pkg_query_name() {
    dpkg-deb --field "$1" Package 2>/dev/null
}

pkg_query_version() {
    dpkg-deb --field "$1" Version 2>/dev/null
}

pkg_query_installed_ver() {
    dpkg-query -W -f '${Version}' "$1" 2>/dev/null
}

pkg_format_list_entry() {
    local name ver
    name=$(dpkg-deb --field "$1" Package 2>/dev/null)
    ver=$(dpkg-deb --field "$1" Version 2>/dev/null)
    echo "${name} ${ver}"
}

pkg_install_files() {
    dpkg -i "$@" || true
    dpkg --configure -a || true
}

pkg_remove_single() {
    dpkg --remove "$1" 2>/dev/null
}

pkg_autoremove() {
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get autoremove -y 2>&1 | tail -5 || true
}

pkg_is_installed() {
    dpkg-query -W -f '${Status}\n' "$1" 2>/dev/null | grep -q "install ok installed"
}

check_os_compat() {
    if [ ! -f /etc/os-release ]; then
        echo "ERROR: Cannot detect OS version (/etc/os-release not found)."
        exit 1
    fi
    local os_id os_version os_major
    os_id=$(. /etc/os-release && echo "$ID")
    os_version=$(. /etc/os-release && echo "$VERSION_ID")
    os_major="${os_version%%.*}"
    if [ "$os_id" != "$EXPECTED_OS_ID" ] || [ "$os_major" != "$EXPECTED_OS_MAJOR" ]; then
        echo "ERROR: ${DISTRO_NAME} packages require ${EXPECTED_OS_ID} ${EXPECTED_OS_MAJOR}.x."
        echo "       Detected: ${os_id} ${os_version}"
        exit 1
    fi
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

    local RUNNING_KVER
    RUNNING_KVER=$(uname -r)

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

    # Pre-filter: skip kernel header packages that don't match running kernel
    # Note: linux-headers-generic is kept for userspace builds, only version-specific headers are filtered
    # When --force is used, all packages are installed regardless of kernel version
    local filtered_files=()
    for pkg_file in "${pkg_files[@]}"; do
        local pn
        pn=$(pkg_query_name "$pkg_file")
        case "$pn" in
            linux-headers-[0-9]*)
                if [ "$force" != "true" ]; then
                    local pv
                    pv=$(pkg_query_version "$pkg_file")
                    if [[ "$RUNNING_KVER" != ${pv}* ]]; then
                        continue
                    fi
                fi
                ;;
        esac
        filtered_files+=("$pkg_file")
    done

    # Build installed-version cache (only actually installed packages)
    declare -A _iv_cache
    while IFS=' ' read -r _iv_status _iv_name _iv_ver; do
        [ -z "$_iv_name" ] && continue
        # Only cache packages with status "install ok installed"
        if [ "$_iv_status" = "install" ]; then
            _iv_cache["$_iv_name"]="$_iv_ver"
        fi
    done < <(dpkg-query -W -f '${db:Status-Abb} ${Package} ${Version}\n' 2>/dev/null | grep '^ii')

    local files_to_install=()
    local skipped=0
    for pkg_file in "${filtered_files[@]}"; do
        local pkg_name file_ver installed_ver
        pkg_name=$(pkg_query_name "$pkg_file")
        file_ver=$(pkg_query_version "$pkg_file")
        installed_ver="${_iv_cache[$pkg_name]:-}"
        if [ -n "$installed_ver" ]; then
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

    # Snapshot post-install state and compute diff (includes all dependencies)
    pkg_list_installed | sort -u > "$post_tmp"
    local new_tmp
    new_tmp=$(mktemp)
    # Compute new packages by NAME (not name-version) to avoid tracking
    # upgrades of pre-existing packages (e.g. coreutils upgraded should not
    # be removed on uninstall, as the system depended on the original version)
    local pre_names_tmp
    pre_names_tmp=$(mktemp)
    awk '{print $1}' "$pre_tmp" | sort -u > "$pre_names_tmp"
    local post_names_tmp
    post_names_tmp=$(mktemp)
    awk '{print $1}' "$post_tmp" | sort -u > "$post_names_tmp"
    comm -13 "$pre_names_tmp" "$post_names_tmp" > "$new_tmp"
    rm -f "$pre_names_tmp" "$post_names_tmp"

    # Merge: existing tracked + new packages
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
    command -v gcc &>/dev/null && gcc --version | head -1
    command -v cmake &>/dev/null && cmake --version | head -1
}

uninstall_packages() {
    echo "============================================"
    echo "  ${DISTRO_NAME} - Uninstalling (soft)"
    echo "============================================"
    echo ""

    if [ ! -f "$INSTALLED_FILE" ]; then
        echo "No installation record found."
        echo ""
        echo "Cleaning up orphaned dependencies..."
        pkg_autoremove
        echo ""
        echo "Uninstall complete."
        return
    fi

    local total
    total=$(wc -l < "$INSTALLED_FILE")
    if [ "$total" -eq 0 ]; then
        echo "Installation record is empty."
        rm -f "$INSTALLED_FILE"
        echo ""
        echo "Uninstall complete."
        return
    fi

    echo "Processing $total tracked packages..."
    echo ""

    local removed=0 skipped_missing=0
    local current_list="$INSTALLED_FILE"
    local pass=0

    while [ -s "$current_list" ]; do
        pass=$((pass + 1))
        local pass_removed=0
        local next_list_tmp
        next_list_tmp=$(mktemp)

        while IFS= read -r pkg_name; do
            [ -z "$pkg_name" ] && continue

            if ! pkg_is_installed "$pkg_name"; then
                skipped_missing=$((skipped_missing + 1))
                continue
            fi

            if is_protected_package "$pkg_name"; then
                echo "  PROTECTED: $pkg_name (system-critical, skipping)"
                continue
            fi

            if pkg_remove_single "$pkg_name"; then
                echo "  REMOVED: $pkg_name"
                removed=$((removed + 1))
                pass_removed=$((pass_removed + 1))
            else
                echo "$pkg_name" >> "$next_list_tmp"
            fi
        done < "$current_list"

        # Clean up old current_list if it's a temp file
        if [ "$current_list" != "$INSTALLED_FILE" ]; then
            rm -f "$current_list"
        fi

        if [ -s "$next_list_tmp" ]; then
            sort -u "$next_list_tmp" > "${next_list_tmp}.dedup" 2>/dev/null
            mv "${next_list_tmp}.dedup" "$next_list_tmp" 2>/dev/null || true
            current_list="$next_list_tmp"
        else
            rm -f "$next_list_tmp"
            current_list=""
            break
        fi

        if [ "$pass_removed" -eq 0 ]; then
            break
        fi
    done

    # Update INSTALLED_FILE with remaining packages
    if [ -n "$current_list" ] && [ -s "$current_list" ]; then
        mv "$current_list" "$INSTALLED_FILE"
        local cannot_remove
        cannot_remove=$(wc -l < "$INSTALLED_FILE")
        echo ""
        echo "Summary: removed=$removed, not-installed=$skipped_missing, cannot-remove=$cannot_remove"
        echo "Retained $cannot_remove package(s) that could not be removed."
    else
        rm -f "$INSTALLED_FILE"
        echo ""
        echo "Summary: removed=$removed, not-installed=$skipped_missing, cannot-remove=0"
    fi

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
    install)    check_os_compat; install_packages "$FORCE" ;;
    uninstall)  uninstall_packages ;;
    list)       list_packages ;;
    help)       usage ;;
    *)          echo "Unknown action: $ACTION"; usage; exit 1 ;;
esac
