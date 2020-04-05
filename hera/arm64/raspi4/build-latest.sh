#!/bin/bash

set -e

VERSION="hera"
TARGET="arm64+raspi4"
COUNTRY=CH
YYYYMMDD="$(date +%Y%m%d)"
OUTPUT_SUFFIX=".img"
TARGET_IMG="elementaryos-${VERSION}-${TARGET}.${YYYYMMDD}${OUTPUT_SUFFIX}"

BASE_IMG_URL="https://github.com/TheRemote/Ubuntu-Server-raspi4-unofficial/releases/download/v28/ubuntu-18.04.4-preinstalled-server-arm64+raspi4.img.xz"
BASE_IMG="ubuntu-18.04.4-preinstalled-server-arm64+raspi4.img"
MountXZ=""

# Setting some colors
BLUE="\033[1;34m"
NC="\033[0m"
NL="\n"

function MountIMG {
  echo -e "${NL}${BLUE}Mounting $TARGET_IMG on loop device...${NC}"
  MountXZ=$(kpartx -avs "$TARGET_IMG")
  sync
  MountXZ=$(echo "$MountXZ" | awk 'NR==1{ print $3 }')
  MountXZ="${MountXZ%p1}"
  echo -e "${NL}${BLUE}Mounted $TARGET_IMG on loop device ${MountXZ}${NC}"
}

function MountIMGPartitions {
  # % Mount the image on /mnt (rootfs)
  mount /dev/mapper/"${MountXZ}"p2 /mnt

  # % Remove overlapping firmware folder from rootfs
  rm -rf /mnt/boot/firmware
  mkdir /mnt/boot/firmware

  # % Mount /mnt/boot/firmware folder from bootfs
  mount /dev/mapper/"${MountXZ}"p1 /mnt/boot/firmware
  sync
  sleep 0.1
}

function UnmountIMGPartitions {
  sync
  sleep 0.1

  echo -e "${NL}${BLUE}Unmounting /mnt/boot/firmware...${NC}"
  while mountpoint -q /mnt/boot/firmware && ! umount /mnt/boot/firmware; do
    sync
    sleep 0.1
  done

  echo -e "${NL}${BLUE}Unmounting /mnt...${NC}"
  while mountpoint -q /mnt && ! umount /mnt; do
    sync
    sleep 0.1
  done

  sync
  sleep 0.1
}

function UnmountIMG {
  sync
  sleep 0.1

  UnmountIMGPartitions

  echo -e "${NL}${BLUE}Unmounting ${TARGET_IMG}...${NC}"
  kpartx -dvs "$TARGET_IMG"

  sleep 0.1

  dmsetup remove ${MountXZ}p1
  dmsetup remove ${MountXZ}p2

  sleep 0.1

  losetup --detach-all /dev/${MountXZ}

  while [ -n "$(losetup --list | grep /dev/${MountXZ})" ]; do
    sync
    sleep 0.1
  done
}

echo -e "${NL}${BLUE}Refreshing package cache...${NC}"
apt update --fix-missing -y

echo -e "${NL}${BLUE}Installing base packages...${NC}"
apt install -y \
  wget \
  xz-utils \
  kpartx \
  qemu-user-static \
  parted \
  zerofree \
  dosfstools

if [ ! -f ${BASE_IMG} ]; then
    echo -e "${NL}${BLUE}Downloading base image...${NC}"
    wget ${BASE_IMG_URL} -O ${BASE_IMG}.xz

    echo -e "${NL}${BLUE}Uncompressing downloaded image...${NC}"
    #unxz ${BASE_IMG}.xz
    xz -d -T 0 -v ${BASE_IMG}.xz 2>&1
fi

echo -e "${NL}${BLUE}Copying ${BASE_IMG} to ${TARGET_IMG}...${NC}"
cp -vf ${BASE_IMG} ${TARGET_IMG}

sync
sleep 5

# Expand the image
echo -e "${NL}${BLUE}Expanding target image...${NC}"
truncate -s 7G "$TARGET_IMG"
sync

sleep 5

MountIMG

# Get the starting offset of the root partition
echo -e "${NL}${BLUE}Running some file system changes...${NC}"
PART_START=$(parted /dev/"${MountXZ}" -ms unit s p | grep ":ext4" | cut -f 2 -d: | sed 's/[^0-9]//g')

# Perform fdisk to correct the partition table
set +e
fdisk /dev/"${MountXZ}" << EOF
p
d
2
n
p
2
$PART_START

p
w
EOF
set -e

# Close and unmount image then reopen it to get the new mapping
UnmountIMG
MountIMG

# Run fsck
echo -e "${NL}${BLUE}Running fsck...${NC}"
e2fsck -fva /dev/mapper/"${MountXZ}"p2
sync
sleep 1

UnmountIMG
MountIMG

# Run resize2fs
echo -e "${NL}${BLUE}Running resize2fs...${NC}"
resize2fs /dev/mapper/"${MountXZ}"p2
sync
sleep 1

UnmountIMG
MountIMG

# Zero out free space on drive to reduce compressed img size
echo -e "${NL}${BLUE}Filling free space with zeros to reduce compressed image size...${NC}"
zerofree -v /dev/mapper/"${MountXZ}"p2
sync
sleep 1

# Map the partitions of the IMG file so we can access the filesystem
MountIMGPartitions

# Configuration for elementary OS
echo -e "${NL}${BLUE}Downloading Netplan configuration files...${NC}"
wget https://raw.githubusercontent.com/elementary/os/master/etc/config/includes.chroot/etc/netplan/01-network-manager-all.yml \
  -O /mnt/etc/netplan/01-network-manager-all.yml

mkdir -p /mnt/etc/NetworkManager/conf.d

echo -e "${NL}${BLUE}Downloading NetworkManager configuration files...${NC}"
wget https://raw.githubusercontent.com/elementary/os/master/etc/config/includes.chroot/usr/lib/NetworkManager/conf.d/10-globally-managed-devices.conf \
  -O /mnt/etc/NetworkManager/conf.d/10-globally-managed-devices.conf

mkdir -p /mnt/etc/oem

echo -e "${NL}${BLUE}Downloading Raspberry Pi logo...${NC}"
wget https://www.raspberrypi.org/app/uploads/2018/03/RPi-Logo-Reg-SCREEN.png \
  -O /mnt/etc/oem/logo.png

echo -e "${NL}${BLUE}Creating OEM configuration file...${NC}"
cat > /mnt/etc/oem.conf << EOF
[OEM]
Manufacturer=Raspberry Pi Foundation
Product=Raspberry Pi
Logo=/etc/oem/logo.png
URL=https://www.raspberrypi.org/
EOF

# setup chroot
echo -e "${NL}${BLUE}Initializing chroot...${NC}"
cp -f /usr/bin/qemu-aarch64-static /mnt/usr/bin

echo -e "${NL}${BLUE}Initializing bind mounts...${NC}"
mount -v --bind /etc/resolv.conf /mnt/etc/resolv.conf
mount -v --bind /dev/pts /mnt/dev/pts
mount -v --bind /proc /mnt/proc
#mount -v --bind /run /mnt/run

# Patch DNS
#echo "${NL}${BLUE}Patching DNS...${NC}"
#echo "1.1.1.1" | tee /mnt/run/systemd/resolve/stub-resolv.conf
#ls -sfvn /mnt/run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf

# chroot
set +e

echo -e "${NL}${BLUE}Starting chrooted environment...${NC}"
chroot /mnt /bin/bash << EOF
# Add elementary OS stable repository
echo -e "${NL}${BLUE}Adding elementary stable repository...${NC}"
add-apt-repository -y ppa:elementary-os/stable

# Add elementary OS patches repository
echo -e "${NL}${BLUE}Adding elementary patches repository...${NC}"
add-apt-repository -y ppa:elementary-os/os-patches

# Refresh package cache manually
echo -e "${NL}${BLUE}Refreshing package cache...${NC}"
apt update --fix-missing -y

# Patch upgrade issues with flash-kernel package
echo -e "${NL}${BLUE}Marking package flash-kernel on hold...${NC}"
apt-mark hold flash-kernel

# Upgrade packages
echo -e "${NL}${BLUE}Upgrading system before proceed...${NC}"
apt update --fix-missing -y && apt dist-upgrade -y

# Install elementary OS packages
echo -e "${NL}${BLUE}Installing elementary OS packages...${NC}"
apt install -y \
  elementary-desktop \
  elementary-minimal \
  elementary-standard

# Install elementary OS initial setup
echo -e "${NL}${BLUE}Installing elementary OS initial setup...${NC}"
apt install -y \
  io.elementary.initial-setup

# Install elementary OS onboarding
echo -e "${NL}${BLUE}Installing elementary OS onboarding...${NC}"
apt install -y \
  io.elementary.onboarding

# Remove unnecessary packages
echo -e "${NL}${BLUE}Removing unnecessary packages...${NC}"
apt purge -y \
  unity-greeter \
  ubuntu-server \
  plymouth-theme-ubuntu-text \
  cloud-init \
  cloud-initramfs* \
  lxd \
  lxd-client \
  acpid \
  gnome-software \
  vim*

# Clean up after ourselves and clean out package cache to keep the image small
echo -e "${NL}${BLUE}Initializing autoremove and package cache clean up...${NC}"
apt autoremove --purge -y
apt clean
apt autoclean
EOF
set -e

echo -e "${NL}${BLUE}Removing bind mounts...${NC}"
umount -v /mnt/etc/resolv.conf
umount -v /mnt/dev/pts
umount -v /mnt/proc
#umount -v /mnt/run

# Remove files needed for chroot
echo -e "${NL}${BLUE}Removing emulator...${NC}"
rm -rf /mnt/usr/bin/qemu-aarch64-static

# Remove any crash files generated during chroot
echo -e "${NL}${BLUE}Removing crash files generated during chroot...${NC}"
rm -rf /mnt/var/crash/*
rm -rf /mnt/var/run/*

# Configuration for elementary OS
echo -e "${NL}${BLUE}Applying some patches...${NC}"
sed -i 's/juno/bionic/g' /mnt/etc/apt/sources.list
sed -i 's/hera/bionic/g' /mnt/etc/apt/sources.list

sed -i 's/ubuntu/elementary/g' /mnt/etc/hostname
sed -i 's/ubuntu/elementary/g' /mnt/etc/hosts

sed -i 's/$/ logo.nologo loglevel=0 quiet splash vt.global_cursor_default=0 plymouth.ignore-serial-consoles/g' /mnt/boot/firmware/cmdline.txt

echo "" >> /mnt/boot/firmware/config.txt
echo "boot_delay=1" >> /mnt/boot/firmware/config.txt

# Patch wireless country code
echo -e "${NL}${BLUE}Patching wireless network country code...${NC}"
sed -Ee 's/REGDOMAIN=\w+/REGDOMAIN='${COUNTRY}'/g' -i /mnt/etc/default/crda

# Recreate ssh host keys
#echo -e "${NL}${BLUE}Recreating SSH host keys...${NC}"
#ssh-keygen -A

# Unmount
UnmountIMGPartitions

# Run fsck on image
echo -e "${NL}${BLUE}Running fsck on the image...${NC}"
fsck.ext4 -pfv /dev/mapper/"${MountXZ}"p2
fsck.fat -av /dev/mapper/"${MountXZ}"p1

echo -e "${NL}${BLUE}Cleaning up image free space...${NC}"
zerofree -v /dev/mapper/"${MountXZ}"p2

# Save image
UnmountIMG

# Create final image
echo -e "${NL}${BLUE}Moving ${TARGET_IMG} to images/${NC}"
mv ${TARGET_IMG} images/
cd images
echo -e "${NL}${BLUE}Removing old image...${NC}"
rm -f ${TARGET_IMG}.xz
echo -e "${NL}${BLUE}Compressing new image...${NC}"
xz -0 -T 0 -ev ${TARGET_IMG} 2>&1
echo -e "${NL}${BLUE}Creating MD5 sum file...${NC}"
md5sum ${TARGET_IMG}.xz > ${TARGET_IMG}.xz.md5
echo -e "${NL}${BLUE}Creating SHA256 sum file...${NC}"
sha256sum ${TARGET_IMG}.xz > ${TARGET_IMG}.xz.sha256
echo -e "${NL}${BLUE}Build process finished.${NC}${NL}"
