#!/bin/bash

# Environment variables for the Anolis OS image
ARCH="x86_64"
OS_VER="7"
OS_REL="7.9"
ROOTFS_FN="AnolisOS-${OS_REL}-GA-${ARCH}-RHCK.qcow2"
ROOTFS_URL="https://mirrors.openanolis.cn/anolis/${OS_REL}/isos/GA/${ARCH}/${ROOTFS_FN}"
# Use ANCK instead when the 4.19 cloud kernel is wanted
# ROOTFS_FN="AnolisOS-${OS_REL}-GA-${ARCH}-ANCK.qcow2"

# Environment variables for Yuk7's wsldl
# icons.zip ships launchers for the distributions wsldl supports, Anolis is not
# one of them; the generic launcher registers the instance under its own exe name
LNCR_BLD="26032000"
LNCR_NAME="Anolis"
LNCR_FN="wsldl.exe"
LNCR_ZIPFN=${LNCR_NAME}${OS_VER}.exe
LNCR_URL="https://github.com/yuk7/wsldl/releases/download/${LNCR_BLD}/${LNCR_FN}"

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

# Download the Anolis OS image and Yuk7's WSLDL
wget --no-verbose ${ROOTFS_URL} -O ${ROOTFS_FN}
wget --no-verbose ${ROOTFS_URL}.md5 -O ${ROOTFS_FN}.md5
wget --no-verbose ${LNCR_URL} -O ${LNCR_FN}

# Check the image against the checksum published by the mirror
md5sum -c ${ROOTFS_FN}.md5 || exit 1
rm ${ROOTFS_FN}.md5

# Mount the qcow2 image
sudo mkdir mntfs
sudo modprobe nbd
sudo qemu-nbd -c /dev/nbd0 --read-only ./${ROOTFS_FN}
waitFile /dev/nbd0p1 "a" 30

# The GA image keeps /boot on its own partition and the root on LVM, so probe
# every block device instead of assuming the root is /dev/nbd0p1
sudo vgchange -ay > /dev/null 2>&1
ROOT_DEV=""
for DEV in /dev/nbd0* /dev/mapper/*; do
  [ -b "${DEV}" ] || continue
  sudo mount -o ro "${DEV}" mntfs 2> /dev/null || continue
  if [ -e mntfs/etc/os-release ] && grep -q 'ID="anolis"' mntfs/etc/os-release; then
    ROOT_DEV=${DEV}
    break
  fi
  sudo umount mntfs
done
if [ -z "${ROOT_DEV}" ]; then
  echo "No Anolis root filesystem found in ${ROOTFS_FN}" >&2
  sudo vgchange -an > /dev/null 2>&1
  sudo qemu-nbd -d /dev/nbd0
  exit 1
fi

# Clone the qcow2 image contents to a writable directory
sudo cp -a mntfs rootfs

# Unmount the qcow2 image
sudo umount mntfs
sudo vgchange -an > /dev/null 2>&1
sudo qemu-nbd -d /dev/nbd0
waitFile /dev/nbd0p1 "d" 30
sudo rmmod nbd
sudo rmdir mntfs

# Clean up
rm ${ROOTFS_FN}

# Configure Alibaba Cloud mirrors for yum, keeping the repo ids of anolis-repos
sudo rm -f rootfs/etc/yum.repos.d/*.repo
sudo tee rootfs/etc/yum.repos.d/AnolisOS-os.repo > /dev/null << 'EOF'
[os]
name=AnolisOS-7.9 - os
baseurl=https://mirrors.aliyun.com/anolis/7.9/os/$basearch/os
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-ANOLIS
EOF
sudo tee rootfs/etc/yum.repos.d/AnolisOS-updates.repo > /dev/null << 'EOF'
[updates]
name=AnolisOS-7.9 - updates
baseurl=https://mirrors.aliyun.com/anolis/7.9/updates/$basearch/os
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-ANOLIS
EOF
sudo tee rootfs/etc/yum.repos.d/AnolisOS-extras.repo > /dev/null << 'EOF'
[extras]
name=AnolisOS-7.9 - extras
baseurl=https://mirrors.aliyun.com/anolis/7.9/extras/$basearch/os
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-ANOLIS
EOF
sudo tee rootfs/etc/yum.repos.d/AnolisOS-Plus.repo > /dev/null << 'EOF'
[Plus]
name=AnolisOS-7.9 - Plus
baseurl=https://mirrors.aliyun.com/anolis/7.9/Plus/$basearch/os
enabled=0
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-ANOLIS
EOF

# WSL cannot relabel the extracted rootfs, and the image ships an enabled
# account with the documented default password anolisos
sudo sed -i 's/^SELINUX=.*/SELINUX=permissive/' rootfs/etc/selinux/config
sudo sed -i 's/^anuser:\([^!][^:]*\)/anuser:!\1/' rootfs/etc/shadow

# Create a tar.gz of the rootfs
sudo tar -zcpf rootfs.tar.gz -C ./rootfs .
sudo chown "$(id -un)" rootfs.tar.gz

# Clean up
sudo rm -rf rootfs

# Create the distribution zip of WSL Anolis
mkdir out
mkdir dist
mv -f ${LNCR_FN} ./out/${LNCR_ZIPFN}
mv -f rootfs.tar.gz ./out/
pushd out
zip -r ../dist/Anolis${OS_VER}.zip ./*
popd

# Clean up
rm -rf out
