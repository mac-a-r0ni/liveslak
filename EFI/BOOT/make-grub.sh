#!/bin/sh

# Copyright 2013  Patrick J. Volkerding, Sebeka, Minnesota, USA
# All rights reserved.
#
# Redistribution and use of this script, with or without modification, is
# permitted provided that the following conditions are met:
#
# 1. Redistributions of this script must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
#
#  THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR IMPLIED
#  WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
#  MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO
#  EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
#  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
#  PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
#  OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
#  WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
#  OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
#  ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

# 30-nov-2015: Modified by Eric Hameleers for Slackware Live Edition.
# 27-dec-2017: Modified by Eric Hameleers, make it compatible with grub-2.02.
# 25-dec-2024: Modified by Eric Hameleers, make it compatible with grub-2.12
#              and Secure Boot.

# Create the 64-bit EFI GRUB binary (bootx64.efi) and the El-Torito boot
# image (efiboot.img) that goes in the /isolinux directory for booting on
# UEFI systems.

# Expectations:
# - grub-embedded.cfg has been GPG-signed before calling this script
# - Grub fonts dejavusansmono5 dejavusansmono15 and dejavusansmono19
#   have already been created
# - grub_sbat.cfg has already been created

# Preparations:
eval $1  # EFIFORM=value1
eval $2  # EFISUFF=value2
eval $3  # EFIDIR=value3
eval $4  # GPGKEY=/path/to/pubkey

# Defaults in case the script was called without parameters:
EFIFORM=${EFIFORM:-"x86_64"}
EFISUFF=${EFISUFF:-"x64"}
EFIDIR=${EFIDIR:-"/EFI/BOOT"}
GPGKEY="none"

# Fix the path in grub-embedded.cfg if needed:
sed -e "s,/EFI/BOOT,${EFIDIR}," -i grub-embedded.cfg

echo
echo "Building ${EFIDIR}/boot${EFISUFF}.efi and /boot/syslinux/efiboot.img."

if [ "${GPGKEY}" != "none" ] && [ -f "${GPGKEY}" ]; then
  echo "Adding GPG public key '${GPGKEY}' for Secure Boot signature check."
  KEYPARAM="--pubkey=${GPGKEY} "boot/grub/grub.cfg.sig=./grub-embedded.cfg.sig""
  SIGNMODS="cryptdisk gcry_sha256 gcry_sha512 gcry_dsa gcry_rsa pgp tpm"
else
  KEYPARAM=" "
  SIGNMODS=" "
fi

# Where are Grub modules located:
GMODDIR="$(dirname $(LANG=C grub-mkimage -O ${EFIFORM}-efi -p ${EFIDIR} alienbob 2>&1 | cut -d\` -f2 |cut -d\' -f1) )"

# Create a list of modules to be added to the efi file, so that the script
# works with multiple grub releases (grub-2.02 added the 'disk' module):
GMODLIST=""
# 'shim_lock' is built into grub, not a module anymore:
for GMOD in \
 all_video \
 at_keyboard \
 bitmap_scale \
 boot \
 btrfs \
 cat \
 chain \
 configfile \
 cpuid \
 disk \
 echo \
 efi_gop \
 efi_uga \
 efifwsetup \
 efinet \
 ext2 \
 extcmd \
 f2fs \
 fat \
 file \
 font \
 gfxmenu \
 gfxterm \
 gfxterm_background \
 gfxterm_menu \
 gzio \
 halt \
 help \
 iso9660 \
 jfs \
 jpeg \
 keystatus \
 linux \
 loadbios \
 loadenv \
 loopback \
 ls \
 lsefi \
 lsefimmap \
 lssal \
 luks \
 lvm \
 memdisk \
 minicmd \
 nativedisk \
 net \
 normal \
 ntfs \
 part_gpt \
 part_msdos \
 password_pbkdf2 \
 png \
 probe \
 reboot \
 regexp \
 search \
 search_fs_file \
 search_fs_uuid \
 search_label \
 sleep \
 smbios \
 tar \
 test \
 tftp \
 tga \
 true \
 usb_keyboard \
 xfs \
 zstd \
 ${SIGNMODS} ; do
  [ -f ${GMODDIR}/${GMOD}.mod ] && GMODLIST="${GMODLIST} ${GMOD}" || echo ">> ${GMOD} not found"
done

# Grub 2.12 has a long-standing bug fixed:
grub-mkstandalone --core-compress=xz 1>/dev/null 2>/dev/null
if [ $? -eq 64 ]; then
  CORECOMPRESS=" "
else
  CORECOMPRESS=" --core-compress=xz "
fi

# Build bootx64.efi/bootia32.efi, which will be installed here in ${EFIDIR}.
grub-mkstandalone \
  --directory ${GMODDIR} \
  --format=${EFIFORM}-efi \
  --install-modules="${GMODLIST}" \
  --modules="part_gpt part_msdos" \
  --fonts="dejavusansmono5 dejavusansmono15 dejavusansmono19" \
  --output=boot${EFISUFF}.efi \
  --sbat=grub_sbat.csv \
  --compress=no \
  --locales="en@quot" \
  --themes="" \
  ${CORECOMPRESS} \
  ${KEYPARAM} \
  "boot/grub/grub.cfg=./grub-embedded.cfg"

# Then, create a FAT formatted image that contains bootx64.efi in the
# ${EFIDIR} directory.  This is used to bootstrap GRUB from the ISO image.
# Allowed sizes are 1440 and 2880.
dd if=/dev/zero of=efiboot.img bs=1K count=2880
# Format the image as FAT12:
mkdosfs -F 12 efiboot.img
# Create a temporary mount point:
MOUNTPOINT=$(mktemp -d)
# Mount the image there:
mount -o loop efiboot.img $MOUNTPOINT
# Copy the GRUB binary to /EFI/BOOT:
mkdir -p $MOUNTPOINT/${EFIDIR}
cp -a boot${EFISUFF}.efi $MOUNTPOINT/${EFIDIR}
# Unmount and clean up:
umount $MOUNTPOINT
rmdir $MOUNTPOINT
# Move the efiboot.img to ../../boot/syslinux:
mv efiboot.img ../../boot/syslinux/

echo
echo "Done building ${EFIDIR}/boot${EFISUFF}.efi and /boot/syslinux/efiboot.img."

