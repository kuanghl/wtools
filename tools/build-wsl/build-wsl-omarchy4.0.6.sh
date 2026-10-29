#!/bin/bash

# Environment variables for the Omarchy ISO
OS_VER="4.0.6"
ISO_FN="omarchy-${OS_VER}.iso"
ISO_URL="https://iso.omarchy.org/${ISO_FN}"

# Environment variables for Yuk7's wsldl
LNCR_BLD="26032000"
LNCR_ZIP="icons.zip"
LNCR_NAME="Omarchy"
LNCR_FN=${LNCR_NAME}.exe
LNCR_ZIPFN=${LNCR_NAME}${OS_VER}.exe
LNCR_URL="https://github.com/yuk7/wsldl/releases/download/${LNCR_BLD}/${LNCR_ZIP}"

# Waits until a file appears or disappears
# - $1   File path to wait for its existence
# - [$2] The string 'a' (default) to wait until the file appears, or 'd' to wait until the file disappears
# - [$3] Timeout in seconds
waitFile() {
  local START
  START=$(cut -d '.' -f 1 /proc/uptime)
  local MODE=${2:-"a"}
  until [[ "${MODE}" = "a" && -e "$1" ]] || [[ "${MODE}" = "d" && ( ! -e "$1" ) ]]; do
    sleep 1s
    if [ -n "$3" ]; then
      local NOW
      NOW=$(cut -d '.' -f 1 /proc/uptime)
      local ELAPSED=$(( NOW - START ))
      if [ $ELAPSED -ge "$3" ]; then break; fi
    fi
  done
  sleep 2s
}

# Create a work dir
mkdir wsl
cd wsl

# Download the Omarchy ISO and Yuk7's WSLDL
wget --no-verbose ${ISO_URL} -O ${ISO_FN}
wget --no-verbose ${LNCR_URL} -O ${LNCR_ZIP}

# Extract the Omarchy WSL launcher
unzip ${LNCR_ZIP} ${LNCR_FN}

# Clean up
rm ${LNCR_ZIP}

# Mount the ISO
sudo mkdir mntfs
sudo mount -o ro ./${ISO_FN} mntfs

# Extract the zstd-compressed btrfs root image from the ISO.
# The Omarchy ISO ships a prebuilt root image at /root.img.zst.
sudo xorriso -osirrox on -indev ./mntfs -extract /root.img.zst root.img.zst

# Unmount the ISO
sudo umount mntfs
sudo rmdir mntfs

# Clean up
rm ${ISO_FN}

# Decompress the root image
zstd -d root.img.zst -o root.img
rm root.img.zst

# Mount the btrfs root image
sudo modprobe nbd
sudo qemu-nbd -c /dev/nbd0 --read-only ./root.img
waitFile /dev/nbd0p1 "a" 30
sudo mount -o ro /dev/nbd0p1 rootfs

# If the btrfs image has no partition table (bare btrfs), mount directly
if [ ! -e /dev/nbd0p1 ]; then
  sudo mount -o ro /dev/nbd0 rootfs
fi

# Clone the root image contents to a writable directory
sudo cp -a rootfs rootfs_copy

# Unmount the root image
sudo umount rootfs
sudo qemu-nbd -d /dev/nbd0
waitFile /dev/nbd0 "d" 30
sudo rmmod nbd
sudo rmdir rootfs

# Clean up
rm root.img
mv rootfs_copy rootfs

# Configure Alibaba Cloud mirrors for pacman
sudo sed -i 's|https\?://geo\.mirror\.pkg\.archlinux\.org|http://mirrors.aliyun.com|g' rootfs/etc/pacman.d/mirrorlist
sudo sed -i 's|https\?://mirror\.pkg\.archlinux\.org|http://mirrors.aliyun.com|g' rootfs/etc/pacman.d/mirrorlist
sudo sed -i 's|https\?://mirror\.edge\.pkg\.archlinux\.org|http://mirrors.aliyun.com|g' rootfs/etc/pacman.d/mirrorlist

# Create a tar.gz of the rootfs
sudo tar -zcpf rootfs.tar.gz -C ./rootfs .
sudo chown "$(id -un)" rootfs.tar.gz

# Clean up
sudo rm -rf rootfs

# Create the distribution zip of WSL Omarchy
mkdir out
mkdir dist
mv -f ${LNCR_FN} ./out/${LNCR_ZIPFN}
mv -f rootfs.tar.gz ./out/
pushd out
zip -r ../dist/Omarchy${OS_VER}.zip ./*
popd

# Clean up
rm -rf out
