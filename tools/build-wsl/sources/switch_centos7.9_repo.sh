#!/bin/bash

# ==============================================================================
# Script: switch_centos_repo.sh
# Description: Idempotently switch CentOS 7.9.2009 YUM repositories to Aliyun
#              mirrors, including standard Base/Updates/Extras and SCL Vault.
# Author: System Administrator
# Run: sudo ./switch_centos7.9_repo.sh
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
# Function: backup_existing_repos
# Description: Backup existing .repo files to a timestamped directory.
#              This prevents data loss and maintains idempotency.
# ------------------------------------------------------------------------------
backup_existing_repos() {
    local backup_dir="/etc/yum.repos.d/backup_$(date +%Y%m%d_%H%M%S)"
    
    echo "--> Backing up existing repository files to ${backup_dir}..."
    mkdir -p "${backup_dir}"
    
    # Move all .repo files to the backup directory if they exist
    if ls /etc/yum.repos.d/*.repo &>/dev/null; then
        mv /etc/yum.repos.d/*.repo "${backup_dir}/"
        echo "    Backup completed."
    else
        echo "    No existing .repo files found. Skipping backup."
    fi
}

# ------------------------------------------------------------------------------
# Function: setup_base_repos
# Description: Configure standard Aliyun CentOS 7.9.2009 repositories.
#              Overwriting the file ensures idempotency.
# ------------------------------------------------------------------------------
setup_base_repos() {
    echo "--> Configuring Aliyun Base repositories (Base, Updates, Extras, Plus)..."
    cat > /etc/yum.repos.d/CentOS-Base.repo <<'EOF'
[base]
name=CentOS-7.9.2009 - Base
baseurl=https://mirrors.aliyun.com/centos/7.9.2009/os/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7

[updates]
name=CentOS-7.9.2009 - Updates
baseurl=https://mirrors.aliyun.com/centos/7.9.2009/updates/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7

[extras]
name=CentOS-7.9.2009 - Extras
baseurl=https://mirrors.aliyun.com/centos/7.9.2009/extras/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7

[centosplus]
name=CentOS-7.9.2009 - Plus
baseurl=https://mirrors.aliyun.com/centos/7.9.2009/centosplus/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=0
EOF
    echo "    Base repositories configured."
}

# ------------------------------------------------------------------------------
# Function: setup_scl_repos
# Description: Configure Aliyun Vault SCL repositories (for devtoolset/GCC 9).
#              Overwriting the file ensures idempotency.
# ------------------------------------------------------------------------------
setup_scl_repos() {
    echo "--> Configuring Aliyun SCL Vault repositories..."
    cat > /etc/yum.repos.d/CentOS-Vault.repo <<'EOF'
[vault-sclo]
name=CentOS-7.9.2009 - Vault SCL
baseurl=https://mirrors.aliyun.com/centos-vault/7.9.2009/sclo/x86_64/sclo/
gpgcheck=0
enabled=1

[vault-rh]
name=CentOS-7.9.2009 - Vault RH
baseurl=https://mirrors.aliyun.com/centos-vault/7.9.2009/sclo/x86_64/rh/
gpgcheck=0
enabled=1
EOF
    echo "    SCL Vault repositories configured."
}

# ------------------------------------------------------------------------------
# Function: refresh_yum_cache
# Description: Clean old cache and build new cache from the new repos.
# ------------------------------------------------------------------------------
refresh_yum_cache() {
    echo "--> Cleaning and rebuilding YUM cache..."
    yum clean all
    yum makecache fast
    echo "    YUM cache rebuilt successfully."
}

# ------------------------------------------------------------------------------
# Function: verify_repos
# Description: Output the active repositories to verify the configuration.
# ------------------------------------------------------------------------------
verify_repos() {
    echo "--> Active YUM repositories:"
    yum repolist
}

# ==============================================================================
# Main Execution Flow
# ==============================================================================
main() {
    echo "=========================================="
    echo " Starting CentOS 7.9 Repository Switch   "
    echo "=========================================="
    
    check_root
    backup_existing_repos
    setup_base_repos
    setup_scl_repos
    refresh_yum_cache
    verify_repos
    
    echo "=========================================="
    echo " Repository switch completed successfully!"
    echo "=========================================="
}

# Execute the main function
main