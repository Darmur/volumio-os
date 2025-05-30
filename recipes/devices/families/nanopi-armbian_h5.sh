#!/usr/bin/env bash
# shellcheck disable=SC2034

## Setup for NanoPi H5 based devices
DEVICE_SUPPORT_TYPE="C" # First letter (Community Porting|Supported Officially|OEM)
DEVICE_STATUS="P"       # First letter (Planned|Test|Maintenance)

# Base system
BASE="Debian"
ARCH="armhf"
BUILD="armv7"
UINITRD_ARCH="arm64" # Instruct mkimage to use the correct architecture on arm{64} devices

### Device information
# This is useful for multiple devices sharing the same/similar kernel
DEVICEFAMILY="armbian"
# tarball from DEVICEFAMILY repo to use
#DEVICEBASE=${DEVICE} # Defaults to ${DEVICE} if unset
DEVICEREPO="https://github.com/volumio/platform-nanopi-${DEVICEFAMILY}"

### What features do we want to target
# TODO: Not fully implement
VOLVARIANT=no # Custom Volumio (Motivo/Primo etc)
MYVOLUMIO=no
VOLINITUPDATER=yes

## Partition info
BOOT_START=1
BOOT_END=64
BOOT_TYPE=msdos          # msdos or gpt
INIT_TYPE="initv3"
INIT_UUID_TYPE="non-uuid-devices" # Use block device GPEN if dynamic UUIDs are not handled.

# Modules that will be added to intramsfs
MODULES=("overlay" "overlayfs" "squashfs" "nls_cp437" "nls_iso8859_1")
# Packages that will be installed
PACKAGES=("bluez-firmware" "bluetooth" "bluez" "bluez-tools")

### Device customisation
# Copy the device specific files (Image/DTS/etc..)
write_device_files() {
  log "Running write_device_files" "ext"

  cp -dR "${PLTDIR}/${DEVICE}/boot" "${ROOTFSMNT}"
  cp -pdR "${PLTDIR}/${DEVICE}/lib/modules" "${ROOTFSMNT}/lib"
  cp -pdR "${PLTDIR}/${DEVICE}/lib/firmware" "${ROOTFSMNT}/lib"
}

write_device_bootloader() {
  log "Running write_device_bootloader" "ext"

  dd if="${PLTDIR}/${DEVICE}/u-boot/u-boot-sunxi-with-spl.bin" of="${LOOP_DEV}" bs=1024 seek=8 conv=notrunc
}

# Will be called by the image builder for any customisation
device_image_tweaks() {
	# log "Performing device_image_tweaks" "ext"
  :
}

# Will be run in chroot - Pre initramfs
device_chroot_tweaks_pre() {
  log "Performing device_chroot_tweaks_pre" "ext"

  echo "Install device tree compiler with overlays support"
  wget -P /tmp http://ftp.debian.org/debian/pool/main/d/device-tree-compiler/device-tree-compiler_1.4.7-4_armhf.deb
  dpkg -i /tmp/device-tree-compiler_1.4.7-4_armhf.deb
  rm /tmp/device-tree-compiler_1.4.7-4_armhf.deb

  log "Adding gpio group and udev rules"
  groupadd -f --system gpio
  usermod -aG gpio volumio
  # Works with newer kernels as well
  cat <<-EOF >/etc/udev/rules.d/99-gpio.rules
	SUBSYSTEM=="gpio*", PROGRAM="/bin/sh -c 'find -L /sys/class/gpio/ -maxdepth 2 -exec chown root:gpio {} \; -exec chmod 770 {} \; || true'"
	EOF
  log "Fixing armv8 deprecated instruction emulation with armv7 rootfs"
  cat <<-EOF >>/etc/sysctl.conf
abi.cp15_barrier=2
EOF
}

# Will be run in chroot - Post initramfs
device_chroot_tweaks_post() {
  # log "Running device_chroot_tweaks_post" "ext"
  :
}

# Will be called by the image builder post the chroot, before finalisation
device_image_tweaks_post() {
  log "Running device_image_tweaks_post" "ext"
  log "Creating uInitrd from 'volumio.initrd'" "info"
  if [[ -f "${ROOTFSMNT}"/boot/volumio.initrd ]]; then
    mkimage -v -A "${UINITRD_ARCH}" -O linux -T ramdisk -C none -a 0 -e 0 -n uInitrd -d "${ROOTFSMNT}"/boot/volumio.initrd "${ROOTFSMNT}"/boot/uInitrd
    rm "${ROOTFSMNT}"/boot/volumio.initrd
  fi
  if [[ -f "${ROOTFSMNT}"/boot/boot.cmd ]]; then
    log "Creating boot.scr"
    mkimage -A arm -T script -C none -d "${ROOTFSMNT}"/boot/boot.cmd "${ROOTFSMNT}"/boot/boot.scr
  fi
}
