#!/bin/bash
set -euo pipefail

# ---- Variables ----

DISTRO_NAME="CentOS 7.9 App Build Dependencies"
INSTALLER_ID="centos7.9-app"
EXPECTED_OS_ID="centos"
EXPECTED_OS_MAJOR="7"
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

pkg_get_requires() {
    rpm -q --requires "$1" 2>/dev/null | awk '{print $1}' | sort -u
}

pkg_check_dep() {
    local dep="$1" check_file="$2"
    local providers
    providers=$(rpm -q --whatprovides "$dep" 2>/dev/null) || return 1
    while IFS= read -r p; do
        [ -z "$p" ] && continue
        grep -qFx "$p" "$check_file" && return 0
    done <<< "$providers"
    return 1
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

    local RUNNING_KVER
    RUNNING_KVER=$(uname -r)
    local kernel_skipped=0

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

    # Pre-filter: skip kernel packages that don't match running kernel
    local filtered_files=()
    for pkg_file in "${pkg_files[@]}"; do
        local pn
        pn=$(pkg_query_name "$pkg_file")
        case "$pn" in
            kernel-devel|kernel-headers)
                local pv
                pv=$(pkg_query_version "$pkg_file")
                if [[ "$RUNNING_KVER" != ${pv}* ]]; then
                    echo "WARNING: $pn version $pv does not match running kernel $RUNNING_KVER, skipping"
                    kernel_skipped=$((kernel_skipped + 1))
                    continue
                fi
                ;;
        esac
        filtered_files+=("$pkg_file")
    done

    if [ "$force" = "true" ]; then
        if [ ${#filtered_files[@]} -gt 0 ]; then
            pkg_install_files "${filtered_files[@]}"
        else
            echo "No packages to install (all kernel packages skipped)."
        fi
    else
        local files_to_install=()
        local skipped=0
        for pkg_file in "${filtered_files[@]}"; do
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

    if [ ! -f "$INSTALLED_FILE" ]; then
        echo "No installation record found."
    else
        local total
        total=$(wc -l < "$INSTALLED_FILE")
        if [ "$total" -eq 0 ]; then
            echo "Installation record is empty."
            rm -f "$INSTALLED_FILE"
        else
            echo "Processing $total tracked packages..."
            echo ""

            local removed=0 skipped_missing=0 skipped_fail=0

            # Build dependency graph and remove in topological order (leaves first).
            # Recomputes the graph each pass so that failed removals don't block progress.
            local current_list="$INSTALLED_FILE"
            local pass=0
            local pass_remaining_tmp=""

            while [ -s "$current_list" ]; do
                pass=$((pass + 1))
                local pass_removed=0

                local dep_of all_installed
                dep_of=$(mktemp)
                all_installed=$(mktemp)
                sort -u "$current_list" > "$all_installed"

                while IFS= read -r pkg; do
                    [ -z "$pkg" ] && continue
                    local req
                    for req in $(pkg_get_requires "$pkg"); do
                        if pkg_check_dep "$req" "$all_installed"; then
                            echo "$pkg" >> "$dep_of"
                            break
                        fi
                    done
                done < "$current_list"
                sort -u "$dep_of" > "${dep_of}.tmp" && mv "${dep_of}.tmp" "$dep_of"

                echo "--- Pass ${pass} (topological) ---"
                pass_remaining_tmp=$(mktemp)

                while IFS= read -r pkg_name; do
                    [ -z "$pkg_name" ] && continue

                    if ! pkg_query_installed_ver "$pkg_name" &>/dev/null; then
                        skipped_missing=$((skipped_missing + 1))
                        continue
                    fi

                    if ! grep -qFx "$pkg_name" "$dep_of"; then
                        if pkg_remove_single "$pkg_name"; then
                            echo "  REMOVED: $pkg_name"
                            removed=$((removed + 1))
                            pass_removed=$((pass_removed + 1))
                        else
                            echo "$pkg_name" >> "$pass_remaining_tmp"
                        fi
                    else
                        echo "$pkg_name" >> "$pass_remaining_tmp"
                    fi
                done < "$current_list"

                rm -f "$dep_of" "$all_installed"

                if [ "$pass_removed" -eq 0 ]; then
                    break
                fi

                sort -u "$pass_remaining_tmp" > "${pass_remaining_tmp}.dedup"
                mv "${pass_remaining_tmp}.dedup" "$pass_remaining_tmp"
                current_list="$pass_remaining_tmp"
            done

            if [ -n "$pass_remaining_tmp" ] && [ -f "$pass_remaining_tmp" ] && [ -s "$pass_remaining_tmp" ]; then
                skipped_fail=$(wc -l < "$pass_remaining_tmp")
            fi

            echo ""
            echo "Summary: removed=$removed, not-installed=$skipped_missing, cannot-remove=$skipped_fail"

            if [ -n "$pass_remaining_tmp" ] && [ -f "$pass_remaining_tmp" ] && [ -s "$pass_remaining_tmp" ]; then
                mv "$pass_remaining_tmp" "$INSTALLED_FILE"
                echo ""
                echo "Retained $(wc -l < "$INSTALLED_FILE") package(s) that could not be removed."
            else
                rm -f "$INSTALLED_FILE" "$pass_remaining_tmp"
            fi
        fi
    fi

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
    install)    check_os_compat; install_packages "$FORCE" ;;
    uninstall)  uninstall_packages ;;
    list)       list_packages ;;
    help)       usage ;;
    *)          echo "Unknown action: $ACTION"; usage; exit 1 ;;
esac
