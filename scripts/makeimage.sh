#!/usr/bin/env bash
# Image creating script

set -eo pipefail
# Bubble up errors from functions so that trap can catch them.
# This should protect against errors in functions from the device template
# Such as write_device_files, write_device_bootloader and friends
set -o errtrace

mount_image_tmp_devices() {
  mount -t ext4 "${IMG_PART}" "${VOLMNT}"/images
  mount -t vfat "${BOOT_PART}" "${ROOTFSMNT}"/boot
}

unmount_image_tmp_devices() {
  umount -l "${VOLMNT}"/images || log "umount ${VOLMNT}/images failed" "wrn"
  umount -l "${ROOTFSMNT}"/boot || log "umount ${ROOTFSMNT}/boot failed" "wrn"
}

clean_loop_devices() {
  log "Cleaning loop device ${LOOP_DEV}" "$(losetup -j "${IMG_FILE}")"
  dmsetup remove_all
  losetup -d "${LOOP_DEV}" || {
    log "Checking loop devices associations" "dbg"
    losetup
  }
}

exit_error() {
  log "Imagebuilder script failed!!" "err"
  # Try and provide some more info about the error
  log "Error stack $(printf '[%s] <= ' "${FUNCNAME[@]:1}")" "err" "$(caller)"
  # Check if there are any mounts that need cleaning up
  if isMounted "${ROOTFSMNT}"/boot; then
    log "Cleaning up image_tmp mounts"
    unmount_image_tmp_devices
  fi
  # If dev is mounted, the rest should also be mounted (right?)
  if isMounted "${ROOTFSMNT}/dev"; then
    unmount_chroot "${ROOTFSMNT}"
  fi
  # Overkill, INT will call exit_error twice
  # So check if we need to cleanup our LOOP_DEV
  # if losetup | grep -q "${LOOP_DEV}"; then
  clean_loop_devices
  # fi
  if [[ -f ${IMG_FILE} ]]; then
    log "Deleting image file"
    rm "${IMG_FILE}"
  fi
}

trap 'exit_error ${LINENO}' INT ERR

IMG_FILE="${OUTPUT_DIR}/${IMG_FILE}"
log "Stage [2]: Creating Image" "info"
log "Image file: ${IMG_FILE}"
log "Using DEBUG_IMAGE: ${DEBUG_IMAGE:-no}"
VOLMNT=${MOUNT_DIR:-'/mnt/volumio'}
IMAGE_END=${IMAGE_END:-2800}
dd if=/dev/zero of="${IMG_FILE}" bs=1M count=$((IMAGE_END + 10))
LOOP_DEV=$(losetup -f --show "${IMG_FILE}")

# Note: leave the first 20Mb free for the firmware
parted -s "${LOOP_DEV}" mklabel "${BOOT_TYPE}"
parted -s "${LOOP_DEV}" mkpart primary fat32 "${BOOT_START:-0}" "${BOOT_END}"
parted -s "${LOOP_DEV}" mkpart primary ext4 "${BOOT_END}" "${IMAGE_END}"
parted -s "${LOOP_DEV}" mkpart primary ext4 "${IMAGE_END}" 100%
parted -s "${LOOP_DEV}" set 1 boot on
[[ "${BOOT_TYPE}" == gpt ]] && parted -s "${LOOP_DEV}" set 1 legacy_boot on # for non UEFI systems
parted -s "${LOOP_DEV}" print
partprobe "${LOOP_DEV}"
kpartx -a "${LOOP_DEV}" -s

BOOT_PART=/dev/mapper/"$(awk -F'/' '{print $NF}' <<<"${LOOP_DEV}")"p1
IMG_PART=/dev/mapper/"$(awk -F'/' '{print $NF}' <<<"${LOOP_DEV}")"p2
DATA_PART=/dev/mapper/"$(awk -F'/' '{print $NF}' <<<"${LOOP_DEV}")"p3

if [[ ! -b "${BOOT_PART}" ]]; then
  log "${BOOT_PART} doesn't exist" "err"
  exit 1
fi

log "Creating filesystem" "info"
mkfs -t vfat -F 32 -n boot "${BOOT_PART}"
# Older kernels may not support metadata checksums (available since Linux 3.6) for Ext4 file systems
# so we let devices pass in extra flags (such as -O ^metadata_csum,^64bit) to disable these features
# that are now default since `e2fsprogs` 1.44 or later
mkfs -F -t ext4 "${FLAGS_EXT4[@]}" -L volumio "${IMG_PART}"
mkfs -F -t ext4 "${FLAGS_EXT4[@]}" -L volumio_data "${DATA_PART}"
#sync

log "Copying Volumio rootfs" "info"

log "Using working tmp dir:" "info" "${VOLMNT}"
if [[ -d ${VOLMNT} ]]; then
  log "Volumio Temp Directory Exists - Cleaning it"
  rm -rf ${VOLMNT:?}/*
else
  log "Creating Volumio Temp Directory"
  mkdir -p "${VOLMNT}"
fi

# Create mount point for image partitions
log "Creating mount point for the images partition"
ROOTFSMNT=${VOLMNT}/rootfs
mkdir "${VOLMNT}/images"
mkdir -p "${ROOTFSMNT}/boot"
# Temp work dir
BUILDTMPDIR=${VOLMNT}/tmp
mkdir "${BUILDTMPDIR}"

mount_image_tmp_devices

#TODO -pPR?
log "Copying Volumio RootFs" "info"
cp -pdR "${ROOTFS}"/* "${ROOTFSMNT}"

# Refactor this to support more binaries
if [[ ${VOLINITUPDATER} == yes ]]; then
  log "Fetching volumio-init-updater"
  {
    wget -O "${ROOTFSMNT}"/usr/local/sbin/volumio-init-updater \
      -nv "${VOLBINSREPO}/${VOLBINS[init_updater]}_${BUILD}"
    chmod +x "${ROOTFSMNT}"/usr/local/sbin/volumio-init-updater
  } || log "Failed installing init-updater" "wrn"
fi

log "Getting device specific files for ${DEVICE} from platform-${DEVICEFAMILY}" "info"
PLTDIR="${SRC}/platform-${DEVICEFAMILY}"

if [[ -d "${PLTDIR}" ]]; then
  log "Platform folder exists, keeping it" "" "platform-${DEVICEFAMILY}"
  HAS_PLTDIR=yes
elif [[ -n "${DEVICEREPO}" ]]; then
  DEVICEREPO_BRANCH="${DEVICEREPO_BRANCH:-main}"
  log "Cloning platform-${DEVICEFAMILY} from ${DEVICEREPO} (branch: ${DEVICEREPO_BRANCH})" "info"
  git clone --branch "${DEVICEREPO_BRANCH}" --depth 1 "${DEVICEREPO}" "platform-${DEVICEFAMILY}"
  HAS_PLTDIR=yes
else
  log "No platform-${DEVICEFAMILY} found, skipping this step" "wrn"
  HAS_PLTDIR=no
fi

# Check if we need to unpack our tarball
# If DEVICEBASE was provided, use it, else default to DEVICE
if [[ "${HAS_PLTDIR}" == yes ]] && [[ ! -d ${PLTDIR}/${DEVICEBASE:=${DEVICE}} ]]; then
  log "Unpacking ${DEVICEBASE} files"
  tar xfJ "platform-${DEVICEFAMILY}/${DEVICEBASE}.tar.xz" -C "${PLTDIR}" || {
    log "This isn't really consistent across platforms right now!" "dbg"
    log "No archive found, assuming you know what you are doing!" "wrn"
  }
fi

if [[ "${HAS_PLTDIR}" == yes ]]; then
  # This is pulled in from each device's config script
  log "Copying ${DEVICE} boot files from platform-${DEVICEFAMILY}/${DEVICEBASE}.tar.xz" "info"

  PLATFORM_ARCHIVE="${PLTDIR}/${DEVICEBASE}.tar.xz"
  PLATFORM_CHUNKS="${PLATFORM_ARCHIVE}.part_"
  TEMP_REASSEMBLED="${PLATFORM_ARCHIVE}.reassembled"

  if ls "${PLATFORM_CHUNKS}"* 1>/dev/null 2>&1; then
    log "Detected chunked platform archive, reassembling..." "info"
    cat "${PLATFORM_CHUNKS}"* > "${TEMP_REASSEMBLED}"
    tar xfJ "${TEMP_REASSEMBLED}" -C "${PLTDIR}/"
    rm -f "${TEMP_REASSEMBLED}"
  elif [[ -f "${PLATFORM_ARCHIVE}" ]]; then
    tar xfJ "${PLATFORM_ARCHIVE}" -C "${PLTDIR}/"
  else
    log "No platform archive found for ${DEVICEBASE}, skipping platform extraction" "wrn"
  fi

  log "Entering write_device_files" "cfg"
  write_device_files
  log "Entering write_device_bootloader" "cfg"
  write_device_bootloader
fi

# Device specific tweaks
log "Performing ${DEVICE} specific tweaks" "info"
log "Entering device_image_tweaks" "cfg"
device_image_tweaks

# Grab the UUIDS for boards that use it
UUID_BOOT="$(blkid -s UUID -o value "${BOOT_PART}")"
UUID_IMG="$(blkid -s UUID -o value "${IMG_PART}")"
UUID_DATA="$(blkid -s UUID -o value "${DATA_PART}")"

log "Adding board pretty name to os-release"
echo "VOLUMIO_DEVICENAME=\"${DEVICENAME:?No DEVICENAME set in device recipe}\"" >>"${ROOTFSMNT}"/etc/os-release
# Ensure all file systems operations are completed before entering chroot again
sync

#### Build stage 2 - Device specific chroot config
log "Preparing to run chroot for more ${DEVICE} configuration" "info"
start_chroot_final=$(date +%s)

log "Copying files for init:" "${INIT_TYPE}"
cp "${SRC}/scripts/initramfs/${INIT_TYPE}" "${ROOTFSMNT}"/root/init
if [[ -d "${SRC}/scripts/initramfs/scripts" ]] && [[ "${INIT_TYPE}" == "initv3" ]]; then
  log "Adding initramfs scripts" "info" "${INIT_UUID_TYPE}"
  [[ -d "${ROOTFSMNT}/root/scripts" ]] || mkdir "${ROOTFSMNT}/root/scripts"
  cp -pdR "${SRC}"/scripts/initramfs/scripts/* "${ROOTFSMNT}/root/scripts"
  # Add in our device specific scripts
  [[ -n ${INIT_UUID_TYPE} ]] && cp "${SRC}/scripts/initramfs/custom/${INIT_UUID_TYPE}/custom-functions" "${ROOTFSMNT}/root/scripts"
fi

cp "${SRC}"/scripts/initramfs/mkinitramfs-custom.sh "${ROOTFSMNT}"/usr/local/sbin
cp "${SRC}"/scripts/image/chrootconfig.sh "${ROOTFSMNT}"

if [[ ${DISABLE_DISPLAY:-no} == "yes" ]]; then
  # Setting some defaults
  [[ -n ${PLYMOUTH_THEME} ]] && log "Conflicting device requirements of DISABLE_DISPLAY: ${DISABLE_DISPLAY} and PLYMOUTH_THEME: ${PLYMOUTH_THEME}" "err"
  unset PLYMOUTH_THEME
  [[ ${KIOSKMODE} == "yes" ]] && log "Conflicting device requirements of DISABLE_DISPLAY: ${DISABLE_DISPLAY} and KIOSKMODE: ${KIOSKMODE}" "err"
  KIOSKMODE="no"
fi

if [[ -n "${PLYMOUTH_THEME}" ]]; then
  log "Copying selected plymouth ${PLYMOUTH_THEME} theme" "info"
  cp -dR "${SRC}/volumio/plymouth/themes/${PLYMOUTH_THEME}" "${ROOTFSMNT}"/usr/share/plymouth/themes/"${PLYMOUTH_THEME}"
fi

if [[ "${INIT_PLYMOUTH_DISABLE}" == yes ]]; then
  log "Disable plymouth in init with ORDER metadata changes" "info"
  cp -dR "${SRC}"/volumio/framebuffer/init/scripts/* "${ROOTFSMNT}"/root/scripts
fi

if [[ "${KIOSKMODE}" == yes ]]; then
  if [[ -f "${SRC}/scripts/components/install-kiosk-${KIOSKBROWSER:=chromium}.sh" ]]; then
    log "Copying scripts to rootfs" "${KIOSKBROWSER}"
    cp "${SRC}/scripts/components/install-kiosk-${KIOSKBROWSER}.sh" "${ROOTFSMNT}"/install-kiosk.sh
  else
    log "Kioskmode enabled, but install-kiosk-${KIOSKBROWSER} was not found!" "err"
  fi
fi

echo "${PATCH}" >"${ROOTFSMNT}"/patch
if [[ -f "${ROOTFSMNT}/${PATCH}/patch.sh" ]] && [[ -f "${SDK_PATH}"/config.js ]]; then
  UIVARIANT=$(if [ -f "UIVARIANT" ]; then cat "UIVARIANT"; else echo "none"; fi)
  log "Starting ${SDK_PATH}/config.js" "ext" "${PATCH}"
  ROOTFSMNT="${ROOTFSMNT}" node "${SDK_PATH}"/config.js "${PATCH}" "${UIVARIANT}" || {
    status=$?
    log "config.js failed: Err ${status}" "err" "${PATCH} | ${UIVARIANT}" && exit 10
  }
  log "Completed config.js" "ext" "${PATCH}"
fi

# Copy across custom bits and bobs from device config
# This is in the hope that <./recipes/devices/${DEVICE}>
# doesn't grow back into the old <xxxxconfig.sh>
BOOT_FS_SPEC="/dev/mmcblk0p1"
[[ "${BOOT_USE_UUID}" == yes ]] && BOOT_FS_SPEC="UUID=${UUID_BOOT}"
log "Setting /boot fs_sepc to ${BOOT_FS_SPEC}"
#TODO: Should we just copy the
# whole thing into the chroot to make life easier?
cat <<-EOF >"${ROOTFSMNT}/chroot_device_config.sh"
DEVICENAME="${DEVICENAME}"
ARCH="${ARCH}"
BUILD="${BUILD}"
UINITRD_ARCH="${UINITRD_ARCH}"
KERNEL_VERSION="${KERNEL_VERSION}"
DEBUG_IMAGE="${DEBUG_IMAGE:-no}"
KIOSKMODE="${KIOSKMODE:-no}"
KIOSKBROWSER="${KIOSKBROWSER}"
KIOSKINSTALL="${KIOSKMODE:-install-kiosk-${KIOSKBROWSER}.sh}"
VARIANT=${VARIANT}
VOLVARIANT="${VOLVARIANT:-volumio}"
BOOT_FS_SPEC=${BOOT_FS_SPEC}
UUID_BOOT=${UUID_BOOT}
UUID_IMG=${UUID_IMG}
UUID_DATA=${UUID_DATA}
BOOT_PART=${BOOT_PART}
LOOP_DEV=${LOOP_DEV}
DISABLE_DISPLAY="${DISABLE_DISPLAY}"
PLYMOUTH_THEME=${PLYMOUTH_THEME}
INIT_PLYMOUTH_DISABLE="${INIT_PLYMOUTH_DISABLE}"
UPDATE_PLYMOUTH_SERVICES_FOR_KMS_DRM="${UPDATE_PLYMOUTH_SERVICES_FOR_KMS_DRM}"
MODULES=($([[ -n ${MODULES} ]] && printf '\"%s\" ' "${MODULES[@]}"))
PACKAGES=($([[ -n ${PACKAGES} ]] && printf '\"%s\" ' "${PACKAGES[@]}"))
$(declare -f device_chroot_tweaks || true)      # Don't trigger our trap when function is empty
$(declare -f device_chroot_tweaks_pre || true)
$(declare -f device_chroot_tweaks_post || true)
EOF

mount_chroot "${ROOTFSMNT}"

log "Calling final chroot config script"
chroot "${ROOTFSMNT}" /chrootconfig.sh

log "Finished chroot config for ${DEVICE}" "okay"
# Clean up chroot stuff
rm "${ROOTFSMNT:?}"/*.sh "${ROOTFSMNT}"/root/init
log "Cleaning legacy sysv-rc leftovers" "okay"
rm "${ROOTFSMNT}"/etc/init.d/README

unmount_chroot "${ROOTFSMNT}"
end_chroot_final=$(date +%s)
time_it "${end_chroot_final}" "${start_chroot_final}"
log "Finished chroot image configuration" "okay" "${TIME_STR}"

log "Entering device_image_tweaks_post" "cfg"
device_image_tweaks_post

log "Finalizing Rootfs (Cleaning, Stripping, Hashing)" "info"
# shellcheck source=./scripts/image/finalize.sh
source "${SRC}/scripts/image/finalize.sh"

log "Rootfs created" "okay"

#### Build stage 3 - Prepare squashfs
log "Preparing rootfs base for SquashFS" "info"

SQSHMNT="${VOLMNT}/squash"
if [[ -d "${SQSHMNT}" ]]; then
  log "Volumio SquashFS Temp Dir Exists - Cleaning it"
  rm -rf "${SQSHMNT:?}"/*
else
  log "Creating Volumio SquashFS Temp Dir at ${SQSHMNT}"
  mkdir "${SQSHMNT}"
fi
log "Copying Volumio rootfs to SquashFS Dir"
cp -rp "${ROOTFSMNT}"/* "${SQSHMNT}"

log "Creating Kernel Partition Archive" "info"
if [[ -e "${VOLMNT}/kernel_current.tar" ]]; then
  log "Volumio Kernel Partition Archive exists - Cleaning it"
  rm -rf "${VOLMNT}/kernel_current.tar"
fi

log "Creating Kernel archive"
# Exclude ldlinux.sys from kernel_current.tar (only present with x86). It is part of the x86 syslinux bootloader
# Rewriting it would result in relocation and a broken x86 legacy boot!
tar cf "${VOLMNT}/kernel_current.tar" --exclude='resize-volumio-datapart' --exclude='ldlinux.sys' \
  -C "${SQSHMNT}/boot/" .

[[ "${CLEAN_IMAGE_FILE:-yes}" != yes ]] && cp -rp "${VOLMNT}"/kernel_current.tar "${OUTPUT_DIR}"/kernel_current.tar
log "Removing the Kernel from SquashFS"
rm -rf "${SQSHMNT:?}"/boot/*

log "Creating SquashFS, removing any previous one" "info"
[[ -f "${SRC}/Volumio.sqsh" ]] && rm "${SRC}/Volumio.sqsh"
mksquashfs "${SQSHMNT}"/* "${SRC}/Volumio.sqsh"

log "Squash filesystem created" "okay" "$(du -h0 "${SRC}/Volumio.sqsh" | cut -f1)"
rm -rf --one-file-system "${SQSHMNT}"

log "Preparing boot partition" "info"
#copy the squash image inside the imgpart partition
cp "${SRC}"/Volumio.sqsh "${VOLMNT}/images/volumio_current.sqsh"
sync

log "Cleaning up" "info"
log "Unmounting temp devices"
unmount_image_tmp_devices

log "Cleaning up loop devices"
clean_loop_devices
sync

log "Clearning up Volumio.sqsh"
[[ "${CLEAN_IMAGE_FILE}" != yes ]] && mv "${SRC}"/Volumio.sqsh "${OUTPUT_DIR}/"
[[ -f "${SRC}"/Volumio.sqsh ]] && rm "${SRC}"/Volumio.sqsh

log "Hashing image" "info"
md5sum "$IMG_FILE" >"${IMG_FILE}.md5"

log "Populating image info file" "info"

cat <<-EOF >"${OUTPUT_DIR}"/image_info
extract_size=$(stat -c%s "${IMG_FILE}")
extract_sha256=$(sha256sum "${IMG_FILE}" | awk '{print $1}')
release_date=$BUILDDATE
EOF
