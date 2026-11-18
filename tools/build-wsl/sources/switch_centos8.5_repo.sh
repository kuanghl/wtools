#!/bin/bash

# ==============================================================================
# Script: switch_centos8_repo.sh
# Description: Idempotently switch CentOS 8.5.2111 YUM/DNF repositories to 
#              Aliyun Vault mirrors.
# Run: sudo ./switch_centos8.5_repo.sh
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
# ------------------------------------------------------------------------------
backup_existing_repos() {
    local backup_dir="/etc/yum.repos.d/backup_$(date +%Y%m%d_%H%M%S)"
    
    echo "--> Backing up existing repository files to ${backup_dir}..."
    mkdir -p "${backup_dir}"
    
    if ls /etc/yum.repos.d/*.repo &>/dev/null; then
        mv /etc/yum.repos.d/*.repo "${backup_dir}/"
        echo "    Backup completed."
    else
        echo "    No existing .repo files found. Skipping backup."
    fi
}

# ------------------------------------------------------------------------------
# Function: setup_baseos_repo
# ------------------------------------------------------------------------------
setup_baseos_repo() {
    echo "--> Configuring Aliyun Vault BaseOS repository..."
    cat > /etc/yum.repos.d/CentOS-Linux-BaseOS.repo <<'EOF'
[baseos]
name=CentOS Linux 8.5.2111 - BaseOS
baseurl=https://mirrors.aliyun.com/centos-vault/8.5.2111/BaseOS/$basearch/os/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial
EOF
}

# ------------------------------------------------------------------------------
# Function: setup_appstream_repo
# ------------------------------------------------------------------------------
setup_appstream_repo() {
    echo "--> Configuring Aliyun Vault AppStream repository..."
    cat > /etc/yum.repos.d/CentOS-Linux-AppStream.repo <<'EOF'
[appstream]
name=CentOS Linux 8.5.2111 - AppStream
baseurl=https://mirrors.aliyun.com/centos-vault/8.5.2111/AppStream/$basearch/os/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial
EOF
}

# ------------------------------------------------------------------------------
# Function: setup_extras_repo
# ------------------------------------------------------------------------------
setup_extras_repo() {
    echo "--> Configuring Aliyun Vault Extras repository..."
    cat > /etc/yum.repos.d/CentOS-Linux-Extras.repo <<'EOF'
[extras]
name=CentOS Linux 8.5.2111 - Extras
baseurl=https://mirrors.aliyun.com/centos-vault/8.5.2111/extras/$basearch/os/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial
EOF
}

# ------------------------------------------------------------------------------
# Function: setup_powertools_repo
# ------------------------------------------------------------------------------
setup_powertools_repo() {
    echo "--> Configuring Aliyun Vault PowerTools repository..."
    cat > /etc/yum.repos.d/CentOS-Linux-PowerTools.repo <<'EOF'
[powertools]
name=CentOS Linux 8.5.2111 - PowerTools
baseurl=https://mirrors.aliyun.com/centos-vault/8.5.2111/PowerTools/$basearch/os/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial
enabled=1
EOF
}

# ------------------------------------------------------------------------------
# Function: refresh_package_cache
# Description: Clean old cache and build new cache from the new repos.
# ------------------------------------------------------------------------------
refresh_package_cache() {
    echo "--> Cleaning and rebuilding DNF/YUM cache..."
    dnf clean all || yum clean all
    dnf makecache || yum makecache
    echo "    Cache rebuilt successfully."
}

# ------------------------------------------------------------------------------
# Function: verify_repos
# Description: Output the active repositories to verify the configuration.
# ------------------------------------------------------------------------------
verify_repos() {
    echo "--> Active YUM/DNF repositories:"
    dnf repolist || yum repolist
}

# ==============================================================================
# Main Execution Flow
# ==============================================================================
main() {
    echo "=========================================="
    echo " Starting CentOS 8.5 Repository Switch   "
    echo "=========================================="
    
    check_root
    backup_existing_repos
    setup_baseos_repo
    setup_appstream_repo
    setup_extras_repo
    setup_powertools_repo
    refresh_package_cache
    verify_repos
    
    echo "=========================================="
    echo " Repository switch completed successfully!"
    echo "=========================================="
}

# Execute the main function
main