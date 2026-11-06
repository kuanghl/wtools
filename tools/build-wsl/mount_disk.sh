#!/bin/bash

# ==========================================
# Linux Universal Disk Mount and Format Script
# (Cross-platform + Idempotent + Logging)
# ==========================================

set -e

# ==========================================
# Global Log Configuration
# ==========================================
LOG_FILE="/var/log/mount_disk.log"

# Color definitions for terminal output
COLOR_INFO="\033[32m"
COLOR_WARN="\033[33m"
COLOR_ERROR="\033[31m"
COLOR_RESET="\033[0m"

# Ensure log file is writable (needs root)
touch "$LOG_FILE" 2>/dev/null || { echo "Cannot write to $LOG_FILE. Please run as root."; exit 1; }

# Unified Logging Interfaces
log_info() {
    local msg="$1"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "${COLOR_INFO}[INFO]${COLOR_RESET} ${msg}"
    echo "[INFO] ${timestamp} - ${msg}" >> "$LOG_FILE"
}

log_warn() {
    local msg="$1"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "${COLOR_WARN}[WARN]${COLOR_RESET} ${msg}"
    echo "[WARN] ${timestamp} - ${msg}" >> "$LOG_FILE"
}

log_error() {
    local msg="$1"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "${COLOR_ERROR}[ERROR]${COLOR_RESET} ${msg}"
    echo "[ERROR] ${timestamp} - ${msg}" >> "$LOG_FILE"
}

# ==========================================
# Core Logic
# ==========================================

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   log_error "Please run this script as root or with sudo."
   exit 1
fi

# Help information
show_help() {
    echo "Usage: sudo $0 [OPTION]"
    echo ""
    echo "Options:"
    echo "  --scan                              Scan and list all current disks, partitions, and filesystems"
    echo "  --format <device> <fstype> [label]  Format device (⚠️ DANGEROUS, supports ext4/xfs, e.g., --format /dev/sdb ext4 data-disk)"
    echo "  --mount <device> <mountpoint>       Mount device and write to /etc/fstab for auto-mount (Idempotent)"
    echo "  --help                              Display this help message"
    echo ""
    echo "log file: $LOG_FILE"
    echo "Examples:"
    echo "  sudo $0 --scan"
    echo "  sudo $0 --mount /dev/sdb1 /data1"
    echo "  sudo $0 --mount /dev/mapper/vg0-lv_home /mnt/data1-sda"
    exit 0
}

# Scan disks (compatible with all Linux versions)
scan_disks() {
    log_info "Scanning system disk information..."
    echo "================ 1. Filesystem and Mount Status (lsblk -f) ================"
    lsblk -f
    
    echo ""
    echo "================ 2. Hardware and Partition Info (fdisk -l) ================"
    if command -v fdisk >/dev/null 2>&1; then
        # Filter out loop devices, show only physical disks and their partitions
        fdisk -l | grep -E "^Disk /dev/(sd|nvme|vd|hd|mapper)|^Device|^/dev/" || true
    else
        log_warn "fdisk command not found, skipping hardware scan."
    fi
    echo "=============================================================="
}

# Format disk
format_disk() {
    local DEV=$1
    local FS_TYPE=$2
    local LABEL=$3

    if [[ -z "$DEV" || -z "$FS_TYPE" ]]; then
        log_error "--format requires a device and filesystem type (e.g., --format /dev/sdb ext4)"
        exit 1
    fi

    if [[ ! -b "$DEV" ]]; then
        log_error "Device $DEV does not exist or is not a block device."
        exit 1
    fi
    
    if mount | grep -q "^$DEV "; then
        log_error "Device $DEV is currently mounted. Please umount it first!"
        exit 1
    fi

    echo -e "${COLOR_WARN}[WARN]${COLOR_RESET} You are about to format $DEV as $FS_TYPE. This will erase all data!"
    read -p "Are you sure you want to continue? (Type YES to confirm): " CONFIRM
    
    # Log user decision
    echo "[INFO] $(date "+%Y-%m-%d %H:%M:%S") - User confirmation for formatting $DEV: $CONFIRM" >> "$LOG_FILE"

    if [[ "$CONFIRM" != "YES" ]]; then
        log_info "Operation cancelled by user."
        exit 1
    fi

    log_info "Formatting $DEV ..."
    if [[ "$FS_TYPE" == "xfs" ]]; then
        if [[ -n "$LABEL" ]]; then mkfs.xfs -f -L "$LABEL" "$DEV"; else mkfs.xfs -f "$DEV"; fi
    elif [[ "$FS_TYPE" == "ext4" ]]; then
        if [[ -n "$LABEL" ]]; then mkfs.ext4 -F -L "$LABEL" "$DEV"; else mkfs.ext4 -F "$DEV"; fi
    else
        log_error "Only ext4 or xfs formats are supported."
        exit 1
    fi
    log_info "Format complete! You can now use --mount to mount it."
}

# Mount and write to fstab (Core idempotency logic)
mount_and_fstab() {
    local DEV=$1
    local MOUNT_POINT=$2

    if [[ -z "$DEV" || -z "$MOUNT_POINT" ]]; then
        log_error "--mount requires a device and a mount point (e.g., --mount /dev/sdb1 /data1)"
        exit 1
    fi

    if [[ ! -b "$DEV" ]]; then
        log_error "Device $DEV does not exist."
        exit 1
    fi

    local UUID=$(blkid -s UUID -o value "$DEV")
    local FSTYPE=$(blkid -s TYPE -o value "$DEV")

    if [[ -z "$UUID" ]]; then
        log_error "Cannot retrieve UUID for $DEV. The device might be unformatted! Please use --format first."
        exit 1
    fi

    # ==========================================
    # Status Check 1: Is the device already mounted?
    # ==========================================
    local DEV_MOUNTED_AT=$(findmnt -n -o TARGET --source "$DEV" 2>/dev/null || true)
    if [[ -n "$DEV_MOUNTED_AT" ]]; then
        if [[ "$DEV_MOUNTED_AT" == "$MOUNT_POINT" ]]; then
            log_warn "Device $DEV is already mounted at $MOUNT_POINT. No action needed."
            if ! grep -q "$UUID" /etc/fstab; then
                log_warn "Device is mounted, but missing from /etc/fstab. It will not persist after reboot!"
                log_info "Please add it manually, or umount $DEV and run this script again."
            fi
            exit 0
        else
            log_warn "Device $DEV is currently mounted at $DEV_MOUNTED_AT."
            log_error "Operation aborted: To prevent service disruption, please umount $DEV manually and try again."
            exit 1
        fi
    fi

    # ==========================================
    # Status Check 2: Is the target directory occupied by another device?
    # ==========================================
    if mountpoint -q "$MOUNT_POINT"; then
        local OTHER_DEV=$(findmnt -n -o SOURCE --target "$MOUNT_POINT" 2>/dev/null || true)
        log_warn "Mount point $MOUNT_POINT is already occupied by another device."
        log_warn "Occupying device: $OTHER_DEV"
        log_error "Operation aborted: Please choose a different mount point or umount the directory first."
        exit 1
    fi

    # ==========================================
    # Status Check 3: Does fstab already have a record?
    # ==========================================
    if grep -q "$UUID" /etc/fstab; then
        local EXISTING_MNT=$(grep "$UUID" /etc/fstab | awk '{print $2}')
        if [[ "$EXISTING_MNT" == "$MOUNT_POINT" ]]; then
            log_warn "/etc/fstab already contains a record for this device with the correct mount point."
            log_info "Attempting to mount according to fstab..."
            mkdir -p "$MOUNT_POINT"
            if mount "$MOUNT_POINT" 2>/dev/null || mount -a; then
                log_info "Mount successful!"
                df -hT "$MOUNT_POINT"
            else
                log_error "Mount failed, please check /etc/fstab."
            fi
        else
            log_warn "/etc/fstab already contains a record for this device, but it's configured for $EXISTING_MNT, which conflicts with your specified $MOUNT_POINT."
            log_error "Operation aborted: Please manually edit /etc/fstab to resolve the conflict."
        fi
        exit 0
    fi

    # ==========================================
    # All status checks passed, execute new mount process
    # ==========================================
    local BACKUP_FILE="/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
    cp /etc/fstab "$BACKUP_FILE"
    log_info "Original fstab backed up to $BACKUP_FILE"

    echo "UUID=$UUID  $MOUNT_POINT  $FSTYPE  defaults,nofail,noatime  0 0" >> /etc/fstab
    log_info "Mount info written to /etc/fstab."

    mkdir -p "$MOUNT_POINT"
    
    log_info "Reloading fstab and mounting..."
    if mount -a; then
        log_info "Mount successful!"
        df -hT | grep -E "Filesystem|$MOUNT_POINT"
    else
        log_error "Mount failed due to an unknown error."
        cp "$BACKUP_FILE" /etc/fstab
        log_warn "/etc/fstab has been rolled back to its previous state."
        exit 1
    fi
}

# ==========================================
# Main program argument parsing
# ==========================================
if [[ $# -eq 0 ]]; then
    show_help
fi

case "$1" in
    --scan)   scan_disks ;;
    --format) shift; format_disk "$@" ;;
    --mount)  shift; mount_and_fstab "$@" ;;
    --help)   show_help ;;
    *)
        log_error "Unknown argument: $1"
        show_help
        ;;
esac