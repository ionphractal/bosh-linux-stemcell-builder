#!/usr/bin/env bash

set -e

base_dir=$(readlink -nf $(dirname $0)/../..)
source $base_dir/lib/prelude_apply.bash

disk_image=${work}/${stemcell_image_name}
image_mount_point=${work}/mnt

## unmap the loop device in case it's already mapped
#umount ${image_mount_point}/proc || true
#umount ${image_mount_point}/sys || true
#umount ${image_mount_point} || true
#losetup -j ${disk_image} | cut -d ':' -f 1 | xargs --no-run-if-empty losetup -d
kpartx -dv ${disk_image}

# note: if the above kpartx command fails, it's probably because the loopback device needs to be unmapped.
# in that case, try this: sudo dmsetup remove loop0p1

# Map partition in image to loopback
device=$(losetup --show --find ${disk_image})
add_on_exit "losetup --verbose --detach ${device}"

device_partition=$(kpartx -sav ${device} | grep "^add" | cut -d" " -f3)
add_on_exit "kpartx -dv ${device}"

loopback_dev="/dev/mapper/${device_partition}"

# Mount partition
image_mount_point=${work}/mnt
mkdir -p ${image_mount_point}

mount ${loopback_dev} ${image_mount_point}
add_on_exit "umount ${image_mount_point}"

# == Guide to variables in this script (all paths are defined relative to the real root dir, not the chroot)

# work: the base working directory outside the chroot
#      eg: /mnt/stemcells/aws/xen/centos/work/work
# disk_image: path to the stemcell disk image
#      eg: /mnt/stemcells/aws/xen/centos/work/work/aws-xen-centos.raw
# device: path to the loopback devide mapped to the entire disk image
#      eg: /dev/loop0
# loopback_dev: device node mapped to the main partition in disk_image
#      eg: /dev/mapper/loop0p1
# image_mount_point: place where loopback_dev is mounted as a filesystem
#      eg: /mnt/stemcells/aws/xen/centos/work/work/mnt

# Generate random password
random_password=$(tr -dc A-Za-z0-9_ < /dev/urandom | head -c 16)

touch ${image_mount_point}${device}
mount --bind ${device} ${image_mount_point}${device}
add_on_exit "umount ${image_mount_point}${device}"

mkdir -p `dirname ${image_mount_point}${loopback_dev}`
touch ${image_mount_point}${loopback_dev}
mount --bind ${loopback_dev} ${image_mount_point}${loopback_dev}
add_on_exit "umount ${image_mount_point}${loopback_dev}"

# GRUB 2 needs /sys and /proc to do its job
mount -t proc none ${image_mount_point}/proc
add_on_exit "umount ${image_mount_point}/proc"

mount -t sysfs none ${image_mount_point}/sys
add_on_exit "umount ${image_mount_point}/sys"

echo "(hd0) ${device}" > ${image_mount_point}/device.map

# install bootsector into disk image file
run_in_chroot ${image_mount_point} "grub-install -v --no-floppy --grub-mkdevicemap=/device.map --target=i386-pc ${device}"

# Enable password-less booting in openSUSE, only editing the boot menu needs to be restricted
run_in_chroot ${image_mount_point} "sed -i 's/CLASS=\\\"--class gnu-linux --class gnu --class os\\\"/CLASS=\\\"--class gnu-linux --class gnu --class os --unrestricted\\\"/' /etc/grub.d/10_linux"

grub_suffix=""
case "${stemcell_infrastructure}" in
aws)
  grub_suffix="nvme_core.io_timeout=4294967295"
  ;;
cloudstack)
  grub_suffix="console=hvc0"
  ;;
esac

## TODO: investigate why we need this fix https://github.com/systemd/systemd/issues/13477
# fixes the monit helper script for finding the net_cls group see line stages/bosh_monit/moint-access-helper.sh:16
CGROUP_FIX="systemd.unified_cgroup_hierarchy=false"

cat >${image_mount_point}/etc/default/grub <<EOF
GRUB_CMDLINE_LINUX="vconsole.keymap=us net.ifnames=0 biosdevname=0 crashkernel=auto selinux=0 plymouth.enable=0 console=ttyS0,115200n8 earlyprintk=ttyS0 rootdelay=300 ipv6.disable=1 audit=1 cgroup_enable=memory swapaccount=1 apparmor=1 security=apparmor ${grub_suffix} ${CGROUP_FIX}"
EOF

# we use a random password to prevent user from editing the boot menu
pbkdf2_password=`run_in_chroot ${image_mount_point} "echo -e '${random_password}\n${random_password}' | grub-mkpasswd-pbkdf2 | grep -Eo 'grub.pbkdf2.sha512.*'"`
echo "\
cat << EOF
set superusers=vcap
set root=(hd0,0)
password_pbkdf2 vcap $pbkdf2_password
EOF" >> ${image_mount_point}/etc/grub.d/00_header

# assemble config file that is read by grub2 at boot time
run_in_chroot ${image_mount_point} "GRUB_DISABLE_RECOVERY=true grub-mkconfig -o /boot/grub/grub.cfg"

# set the correct root filesystem; use the ext2 filesystem's UUID
device_uuid=$(dumpe2fs $loopback_dev | grep UUID | awk '{print $3}')
sed -i s%root=${loopback_dev}%root=UUID=${device_uuid}%g ${image_mount_point}/boot/grub/grub.cfg

rm ${image_mount_point}/device.map

# Figure out uuid of partition
uuid=$(blkid -c /dev/null -sUUID -ovalue ${loopback_dev})
kernel_version=$(basename $(ls -rt ${image_mount_point}/boot/vmlinuz-* |tail -1) |cut -f2-8 -d'-')
initrd_file="initrd.img-${kernel_version}"
os_name=$(source ${image_mount_point}/etc/lsb-release ; echo -n ${DISTRIB_DESCRIPTION})

cat > ${image_mount_point}/etc/fstab <<FSTAB
# /etc/fstab Created by BOSH Stemcell Builder
UUID=${uuid} / ext4 defaults 1 1
FSTAB

chown -fLR root:root ${image_mount_point}/boot/grub/grub.cfg
chmod 600 ${image_mount_point}/boot/grub/grub.cfg

run_in_chroot ${image_mount_point} "rm -f /boot/grub/menu.lst"
run_in_chroot ${image_mount_point} "ln -s ./grub.cfg /boot/grub/menu.lst"
