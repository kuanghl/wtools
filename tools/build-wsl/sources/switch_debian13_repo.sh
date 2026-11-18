#!/bin/bash

# ==============================================================================
# Script: switch_debian13_repo.sh
# Description: Idempotently switch Debian 13 (Trixie) APT repositories to
#              Aliyun mirrors. Debian 13 ships its sources in deb822 format
#              (/etc/apt/sources.list.d/debian.sources); any classic
#              sources.list entry is disabled so no official-archive host stays
#              active alongside the new one.
# Run: sudo ./switch_debian13_repo.sh
# ==============================================================================

set -e # Exit immediately if a command exits with a non-zero status

MIRROR_HOST="mirrors.aliyun.com"
CODENAME="trixie"
DEB822_FILE="/etc/apt/sources.list.d/debian.sources"
SOURCE_FILE="/etc/apt/sources.list"

# ------------------------------------------------------------------------------
# Function: check_root
# Description: Verify if the script is run with root privileges
# ------------------------------------------------------------------------------
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "Error: This script must be run as root." >&2
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# Function: check_release
# Description: Refuse to run on anything other than Debian 13 (trixie). Writing
#              trixie suites onto another release would leave apt with a source
#              list it cannot satisfy.
# ------------------------------------------------------------------------------
check_release() {
    local os_id="" codename=""

    if [ -f /etc/os-release ]; then
        os_id=$(. /etc/os-release 2>/dev/null && echo "${ID:-}" || true)
        codename=$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}" || true)
    fi

    if [ "$os_id" != "debian" ] || [ "$codename" != "$CODENAME" ]; then
        echo "Error: this script only targets Debian 13 (${CODENAME})." >&2
        echo "       Detected: ${os_id:-unknown} ${codename:-unknown-codename}" >&2
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# Function: backup_existing_sources
# Description: Copy every existing source file to a timestamped directory.
# ------------------------------------------------------------------------------
backup_existing_sources() {
    local backup_dir="/etc/apt/backup_$(date +%Y%m%d_%H%M%S)"
    local source_file basename found=0

    echo "--> Backing up existing APT sources..."
    for source_file in "$SOURCE_FILE" "$DEB822_FILE"; do
        [ -f "$source_file" ] || continue
        mkdir -p "${backup_dir}"
        basename=$(basename "$source_file")
        cp "$source_file" "${backup_dir}/${basename}.bak"
        echo "    Backup completed at ${backup_dir}/${basename}.bak"
        found=1
    done

    if [ "$found" -eq 0 ]; then
        echo "    No existing source files found. Skipping backup."
    fi
}

# ------------------------------------------------------------------------------
# Function: configure_aliyun_sources
# Description: Write the Aliyun Debian 13 (Trixie) deb822 configuration.
#              Overwriting the file ensures idempotency. Components stay at
#              "main", matching the image default: this script only moves the
#              download host, it does not widen what is installable.
# ------------------------------------------------------------------------------
configure_aliyun_sources() {
    echo "--> Configuring Aliyun Debian 13 APT sources (${DEB822_FILE})..."
    mkdir -p "$(dirname "$DEB822_FILE")"
    cat > "$DEB822_FILE" <<EOF
Types: deb
URIs: http://${MIRROR_HOST}/debian
Suites: ${CODENAME} ${CODENAME}-updates ${CODENAME}-backports
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://${MIRROR_HOST}/debian-security
Suites: ${CODENAME}-security
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
    echo "    APT sources configured."

    # apt reads every source file at once, so a classic sources.list still pointing
    # at deb.debian.org would keep being fetched (and duplicate these blocks).
    if [ -f "$SOURCE_FILE" ] \
        && grep -qE '^[[:space:]]*deb(-src)?[[:space:]]' "$SOURCE_FILE"; then
        echo "--> Disabling classic ${SOURCE_FILE} (original kept in the backup dir)..."
        cat > "$SOURCE_FILE" <<EOF
# Debian sources are managed in deb822 format by ${DEB822_FILE}.
# The previous file is backed up under /etc/apt/backup_*/sources.list.bak.
EOF
    fi
}

# ------------------------------------------------------------------------------
# Function: refresh_apt_cache
# Description: Update the APT package lists to apply the new sources.
# ------------------------------------------------------------------------------
refresh_apt_cache() {
    echo "--> Refreshing APT cache..."
    apt-get update
    echo "    APT cache updated successfully."
}

# ------------------------------------------------------------------------------
# Function: verify_repos
# Description: Show the hosts apt actually resolved, to prove no official
#              archive host is left.
# ------------------------------------------------------------------------------
verify_repos() {
    echo "--> Repository hosts in use:"
    apt-cache policy | grep -oE 'https?://[^/[:space:]]+' | sort -u
}

# ==============================================================================
# Main Execution Flow
# ==============================================================================
main() {
    echo "========================================="
    echo " Starting Debian 13 Repository Switch "
    echo "========================================="

    check_root
    check_release
    backup_existing_sources
    configure_aliyun_sources
    refresh_apt_cache
    verify_repos

    echo "=========================================="
    echo " Repository switch completed successfully!"
    echo "=========================================="
}

# Execute the main function
main
