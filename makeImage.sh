#!/bin/bash

set -e
set -u

if [ -e ./firmadyne.config ]; then
    source ./firmadyne.config
elif [ -e ../firmadyne.config ]; then
    source ../firmadyne.config
else
    echo "Error: Could not find 'firmadyne.config'!"
    exit 1
fi

if check_number $1; then
    echo "Usage: makeImage.sh <image ID> [<architecture]"
    exit 1
fi
IID=${1}

if check_root; then
    echo "Error: This script requires root privileges!"
    exit 1
fi

if [ $# -gt 1 ]; then
    if check_arch "${2}"; then
        echo "Error: Invalid architecture!"
        exit 1
    fi

    ARCH=${2}
else
    echo -n "Querying database for architecture... "
    ARCH=$(psql -d firmware -U firmadyne -h 127.0.0.1 -t -q -c "SELECT arch from image WHERE id=${1};")
    ARCH="${ARCH#"${ARCH%%[![:space:]]*}"}"
    echo "${ARCH}"
    if [ -z "${ARCH}" ]; then
        echo "Error: Unable to lookup architecture. Please specify {armel,mipseb,mipsel} as the second argument!"
        exit 1
    fi
fi

echo "----Running----"
WORK_DIR=`get_scratch ${IID}`
IMAGE=`get_fs ${IID}`
IMAGE_DIR=`get_fs_mount ${IID}`
CONSOLE=`get_console ${ARCH}`
LIBNVRAM=`get_nvram ${ARCH}`

echo "----Copying Filesystem Tarball----"
mkdir -p "${WORK_DIR}"
chmod a+rwx "${WORK_DIR}"
chown -R "${USER}" "${WORK_DIR}"
chgrp -R "${USER}" "${WORK_DIR}"

if [ ! -e "${WORK_DIR}/${IID}.tar.gz" ]; then
    if [ ! -e "${TARBALL_DIR}/${IID}.tar.gz" ]; then
        echo "Error: Cannot find tarball of root filesystem for ${IID}!"
        exit 1
    else
        cp "${TARBALL_DIR}/${IID}.tar.gz" "${WORK_DIR}/${IID}.tar.gz"
    fi
fi

echo "----Creating QEMU Image----"
qemu-img create -f raw "${IMAGE}" 1G
chmod a+rw "${IMAGE}"

echo "----Creating Partition Table----"
echo -e "o\nn\np\n1\n\n\nw" | /sbin/fdisk "${IMAGE}"

echo "----Mounting QEMU Image----"
DEVICE=$(get_device "$(kpartx -a -s -v "${IMAGE}")")
sleep 1

echo "----Creating Filesystem----"
mkfs.ext2 "${DEVICE}"
sync

echo "----Making QEMU Image Mountpoint----"
if [ ! -e "${IMAGE_DIR}" ]; then
    mkdir "${IMAGE_DIR}"
    chown "${USER}" "${IMAGE_DIR}"
fi

echo "----Mounting QEMU Image Partition 1----"
mount "${DEVICE}" "${IMAGE_DIR}"

echo "----Extracting Filesystem Tarball----"
tar -xf "${WORK_DIR}/$IID.tar.gz" -C "${IMAGE_DIR}"
rm "${WORK_DIR}/${IID}.tar.gz"

echo "----Creating FIRMADYNE Directories----"
mkdir "${IMAGE_DIR}/firmadyne/"
#mkdir "${IMAGE_DIR}/FILE_LOAD/" #new
mkdir "${IMAGE_DIR}/firmadyne/libnvram/"
mkdir "${IMAGE_DIR}/firmadyne/libnvram.override/"

echo "----Patching Filesystem (chroot)----"
cp $(which busybox) "${IMAGE_DIR}"
cp "${SCRIPT_DIR}/fixImage.sh" "${IMAGE_DIR}"
#cp  -a "${FIRMWARE_DIR}/FILE_LOAD/." "${IMAGE_DIR}/FILE_LOAD/" #new
chroot "${IMAGE_DIR}" /busybox ash /fixImage.sh
rm "${IMAGE_DIR}/fixImage.sh"
rm "${IMAGE_DIR}/busybox"

#new
#rm "${IMAGE_DIR}/usr/sbin/gpiod" #9054
#rm "${IMAGE_DIR}/etc/init.d/S45gpiod.sh" #9050 dlink
#cp "${IMAGE_DIR}/userfs/bin/tcapi" "${IMAGE_DIR}/userfs/bin/tcapi_new" #105609 DSL-3782
#rm "${IMAGE_DIR}/usr/sbin/fresetd" #9925
#cp "../firmadyne_modify/webs_9925.sh" "${IMAGE_DIR}/etc/templates/webs.sh" #9925
#cp "../firmadyne_modify/http-loop_9925.sh" "${IMAGE_DIR}/http-loop.sh" #9925
#cp "HTTP.php_10098" "${IMAGE_DIR}/etc/services/HTTP.php" #image_10098

echo "----Setting up FIRMADYNE----"
cp "${CONSOLE}" "${IMAGE_DIR}/firmadyne/console"
chmod a+x "${IMAGE_DIR}/firmadyne/console"
#chmod -R a+x "${IMAGE_DIR}/FILE_LOAD/" #new
mknod -m 666 "${IMAGE_DIR}/firmadyne/ttyS1" c 4 65

cp "${LIBNVRAM}" "${IMAGE_DIR}/firmadyne/libnvram.so"
chmod a+x "${IMAGE_DIR}/firmadyne/libnvram.so"

cp "${SCRIPT_DIR}/preInit.sh" "${IMAGE_DIR}/firmadyne/preInit.sh"
chmod a+x "${IMAGE_DIR}/firmadyne/preInit.sh"

cp -r "${IMAGE_DIR}" "${FIRMWARE_DIR}/image_${IID}" #new

echo "----Unmounting QEMU Image----"
sync
umount "${DEVICE}"
kpartx -d "${IMAGE}"
losetup -d "${DEVICE}" &>/dev/null
dmsetup remove $(basename "$DEVICE") &>/dev/null