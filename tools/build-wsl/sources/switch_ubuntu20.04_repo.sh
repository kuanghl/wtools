#!/bin/bash

# ==============================================================================
# Script: switch_ubuntu_repo.sh
# Description: Idempotently switch Ubuntu 20.04 (Focal) APT repositories to 
#              Aliyun mirrors.
# Run: sudo ./switch_ubuntu20.04_repo.sh
# ==============================================================================

set -e # Exit immediately if a command exits with a non-zero status

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
# Function: backup_existing_sources
# Description: Backup the existing sources.list to a timestamped file.
# ------------------------------------------------------------------------------
backup_existing_sources() {
    local source_file="/etc/apt/sources.list"
    local backup_dir="/etc/apt/backup_$(date +%Y%m%d_%H%M%S)"
    
    echo "--> Backing up existing APT sources..."
    if [ -f "$source_file" ]; then
        mkdir -p "${backup_dir}"
        cp "$source_file" "${backup_dir}/sources.list.bak"
        echo "    Backup completed at ${backup_dir}/sources.list.bak"
    else
        echo "    No existing sources.list found. Skipping backup."
    fi
}

# ------------------------------------------------------------------------------
# Function: configure_aliyun_sources
# Description: Write the Aliyun Ubuntu 20.04 (Focal) mirror configuration.
#              Overwriting the file ensures idempotency.
# ------------------------------------------------------------------------------
configure_aliyun_sources() {
    echo "--> Configuring Aliyun Ubuntu 20.04 APT sources..."
    cat > /etc/apt/sources.list <<'EOF'
deb http://mirrors.aliyun.com/ubuntu/ focal main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu/ focal-security main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu/ focal-updates main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu/ focal-backports main restricted universe multiverse
EOF
    echo "    APT sources configured."
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

# ==============================================================================
# Main Execution Flow
# ==============================================================================
main() {
    echo "=========================================="
    echo " Starting Ubuntu 20.04 Repository Switch "
    echo "=========================================="
    
    check_root
    backup_existing_sources
    configure_aliyun_sources
    refresh_apt_cache
    
    echo "=========================================="
    echo " Repository switch completed successfully!"
    echo "=========================================="
}

# Execute the main function
main