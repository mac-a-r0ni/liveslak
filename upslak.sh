#!/bin/bash
#
# Copyright 2017, 2019, 2021, 2022, 2023  Eric Hameleers, Eindhoven, NL
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

# -----------------------------------------------------------------------------
#
# This script can perform the following changes on
# the USB version of on Slackware Live Edition.
# - upgrade the kernel and modules
# - add network support modules for PXE boot (if missing)
# - increase (or decrease) USB wait time during boot
# - replace the Live init script inside the initrd image
# - move current persistence data to a new squashfs module in 'addons'
#
# -----------------------------------------------------------------------------

# Be careful:
set -e

# Limit the search path:
export PATH="/usr/sbin:/sbin:/usr/bin:/bin"

# ---------------------------------------------------------------------------
# START possible tasks to be executed by the script:
# ---------------------------------------------------------------------------

# By default do not move persistence data into a new Live module:
CHANGES2SXZ=0

# Replace the live 'init' script with the file $LIVEINIT:
LIVEINIT=""

# Do we need to add network support? This can be enforced through commandline,
# otherwise will be determined by examining the original kernelmodules:
NETSUPPORT=""

# This will be set to '1' if the user wants to restore the backups of the
# previous kernel and modules:
RESTORE=0

# Set default for 'do we update the kernel':
UPKERNEL=0

# Do not change usb wait time by default:
WAIT=-1

# Not extending any container by default:
EXTENSION=""

# ---------------------------------------------------------------------------
# END possible tasks to be executed by the script:
# ---------------------------------------------------------------------------

# The extension for containerfiles accompanying an ISO is '.icc',
# whereas the persistent USB stick created with iso2usb.sh uses '.img'.
DEFEXT=".img"
CNTEXT="${DEFEXT}"

# Default filesystem for devices/containers:
DEF_FS="ext4"
FSYS="${DEF_FS}"

# Determine whether the USB stick has a supported kernel configuration
# i.e. one active and optionally one backup kernel plus mmodules:
SUPPORTED=1

# Values obtained from the init script on the USB:
CORE2RAMMODS=""
DEF_KBD=""
DEF_LOCALE=""
DEF_TZ=""
DISTRO=""
LIVE_HOSTNAME=""
LIVEMAIN=""
LIVEUID=""
MARKER=""
MEDIALABEL=""
PERSISTENCE=""
SQ_EXT_AVAIL=""
VERSION=""

# By default we make a backup of your old kernel/modules when adding new ones:
KBACKUP=1

# Does the initrd contain an old kernel that we can restore?
# The 'read_initrddir' routine may set this to '0':
KRESTORE=1

# By default we create an addon live module for the new kernel modules,
# otherwise the Live OS will be broken after reboot.
# User can skip this if they already installed the kernel-modules package
# in the Live OS earlier:
NOLIVEMODS=0

# Timeout when scanning for inserted USB device, 30 seconds by default,
# but this default can be changed from outside the script:
SCANWAIT=${SCANWAIT:-30}

# By default do not show file operations in detail:
VERBOSE=0

# Set to '1' if we are to scan for device insertion:
SCAN=0

# Minimim free space (in MB) we want to have left in any partition
# after we are done.
# The default value can be changed from the environment:
MINFREE=${MINFREE:-10}

# Variables to store content from an initrd we are going to refresh:
OLDKERNELSIZE=""
OLDKMODDIRSIZE=""
OLDWAIT=""

# Record the version of the new kernel:
KVER=""

# Define ahead of time, so that cleanup knows about them:
IMGDIR=""
KERDIR=""
USBMNT=""
EFIMNT=""
CNTDEV=""
LODEV=""

# Empty initialization:
INCSIZE=""
PARTFREE=""
PARTSIZE=""

# These tools are required by the script, we will check for their existence:
REQTOOLS="cpio gdisk inotifywait lsblk strings xz"

# Minimim free space (in MB) we want to have left in any partition
# after we are done.
# The default value can be changed from the environment:
MINFREE=${MINFREE:-10}

# Compressor used on the initrd ("gzip" or "xz --check=crc32");
# Note that the kernel's XZ decompressor does not understand CRC64:
COMPR="xz --check=crc32"

# -- START: Taken verbatim from make_slackware_live.sh -- #
# List of kernel modules required for a live medium to boot properly;
# Lots of HID modules added to support keyboard input for LUKS password entry;
# Virtio modules added to experiment with liveslak in a VM.
KMODS=${KMODS:-"squashfs:overlay:loop:efivarfs:xhci-pci:ohci-pci:ehci-pci:xhci-hcd:uhci-hcd:ehci-hcd:mmc-core:mmc-block:sdhci:sdhci-pci:sdhci-acpi:rtsx_pci:rtsx_pci_sdmmc:usb-storage:uas:hid:usbhid:i2c-hid:hid-generic:hid-apple:hid-cherry:hid-logitech:hid-logitech-dj:hid-logitech-hidpp:hid-lenovo:hid-microsoft:hid_multitouch:jbd:mbcache:ext3:ext4:zstd_compress:lz4hc_compress:lz4_compress:btrfs:f2fs:jfs:xfs:isofs:fat:nls_cp437:nls_iso8859-1:msdos:vfat:exfat:ntfs:virtio_ring:virtio:virtio_blk:virtio_balloon:virtio_pci:virtio_pci_modern_dev:virtio_net"}

# Network kernel modules to include for NFS root support:
NETMODS="kernel/drivers/net kernel/drivers/virtio"

# Network kernel modules to exclude from above list:
NETEXCL="appletalk arcnet bonding can dummy.ko hamradio hippi ifb.ko irda macvlan.ko macvtap.ko pcmcia sb1000.ko team tokenring tun.ko usb veth.ko wan wimax wireless xen-netback.ko"
# -- END: Taken verbatim from make_slackware_live.sh -- #

#
#  -- function definitions --
#

# Clean up in case of failure:
function cleanup() {
  # Clean up by unmounting our loopmounts, deleting tempfiles:
  echo "--- Cleaning up the staging area..."
  # During cleanup, do not abort due to non-zero exit code:
  set +e
  sync

  if [ -n "$CNTDEV" ]; then
    # In case of failure, only most recent LUKS mapped device is still open:
    if mount | grep -q ${CNTDEV} ; then
      umount -f ${CNTDEV}
      cryptsetup luksClose $(basename ${CNTDEV})
      losetup -d ${LODEV}
    fi
  fi

  # No longer needed:
  [ -n "${IMGDIR}" ] && ( rm -rf $IMGDIR )
  [ -n "${KERDIR}" ] && ( rm -rf $KERDIR )
  if [ -n "${USBMNT}" ]; then
    if mount |grep -qw ${USBMNT} ; then umount ${USBMNT} ; fi
    rmdir $USBMNT
  fi
  if [ -n "${EFIMNT}" ]; then
    if mount |grep -qw ${EFIMNT} ; then umount ${EFIMNT} ; fi
    rmdir $EFIMNT
  fi
  set -e
} # End of cleanup()

trap 'echo "*** $0 FAILED at line $LINENO ***"; cleanup; exit 1' ERR INT TERM

# Show the help text for this script:
function showhelp() {
cat <<EOT
#
# Purpose: to update the content of a Slackware Live USB stick.
#
# $(basename $0) accepts the following parameters:
#   -b|--nobackup              Do not try to backup original kernel and modules.
#   -d|--devices               List removable devices on this computer.
#   -e|--examples              Show some common usage examples.
#   -h|--help                  This help.
#   -i|--init <filename>       Replacement init script.
#   -k|--kernel <filename>     The kernel file (or package).
#   -m|--kmoddir <name>        The kernel modules directory (or package).
#   -n|--netsupport            Add network boot support if not yet present.
#   -o|--outdev <filename>     The device name of your USB drive.
#   -p|--persistence           Move persistent data into new Live module.
#   -r|--restore               Restore previous kernel and modules.
#   -s|--scan                  Scan for insertion of new USB device instead of
#                              providing a devicename (using option '-o').
#   -v|--verbose               Show verbose messages.
#   -w|--wait<number>          Add <number> seconds wait time to initialize USB.
#   -x|--extend <fullpath>     Full path (either in your filesystem or else
#                              relative to the USB partition root)
#                              to an existing (encrypted) container file,
#                              whose size you want to extend.
#                              Limitations:
#                              - container needs to be LUKS encrypted.
#                              - filename extension needs to be '${CNTEXT}'.
#                              Supported filesystems inside container:
#                              - $(resizefs).
#   -N|--nolivemods            Don't create an addon live module containing
#                              the new kernelmodules. Normally you *will* need
#                              this addon module, *unless* you have already
#                              installed these kernel-modules in the Live OS.
#                              FYI: the kernel and module upgrade applies only
#                              to the USB boot kernel and its initrd.
#   -X|--extendsize <size|perc> Extend size of existing container; value
#                              is the requested extension of the container
#                              in kB, MB, GB, or as percentage of free space
#                              (integer numbers only).
#                              Examples: '-X 125M', '-X 2G', '-X 20%'.
#
EOT
} # End of showhelp()

function showexamples() {
cat <<EOT
#
# Some common usage examples for $(basename $0)
# ---------------------------------------------------------------------------
#
# Get a listing of all available removable devices on the computer:
#   ./$(basename $0) -d
#
# Updating kernel and modules, providing two packages as input and assuming
# that the USB stick is known as /dev/sdX:
#   ./$(basename $0) -o /dev/sdX -m kernel-modules-4.19.0-x86_64-1.txz -k kernel-generic-4.19.0-x86_64-1.txz
#
# Restore the previous kernel and modules after a failed update,
# and let the script scan your computer for the insertion of your USB stick:
#   ./$(basename $0) -s -r
#
# Replace the Live init script with the latest template taken from
# the liveslak git repository:
#   wget https://git.liveslak.org/liveslak/plain/liveinit.tpl
#   ./$(basename $0) -o /dev/sdX -i liveinit.tpl
#
# Extend the size of the pre-existing LUKS container for your homedirectory
# with 3 GB, and let the script scan for the insertion of your USB stick:
#    ./$(basename $0) -s -x /slhome.img -X 3G
#
EOT
} # End of showexamples()

# Scan for insertion of a USB device:
function scan_devices() {
  local MYSCANWAIT="${1}"
  local BD
  # Inotifywatch does not trigger on symlink creation,
  # so we can not watch /sys/block/
  BD=$(inotifywait -q -t ${MYSCANWAIT} -e create /dev 2>/dev/null |cut -d' ' -f3)
  echo ${BD}
} # End of scan_devices()

# Show a list of removable devices detected on this computer:
function show_devices() {
  local MYDATA="${*}"
  if [ -z "${MYDATA}" ]; then
    MYDATA="$(ls --indicator-style=none /sys/block/ |grep -Ev '(ram|loop|dm-)')"
  fi
  echo "# Removable devices detected on this computer:"
  for BD in ${MYDATA} ; do
    if [ $(cat /sys/block/${BD}/removable) -eq 1 ]; then
      echo "# /dev/${BD} : $(cat /sys/block/${BD}/device/vendor 2>/dev/null) $(cat /sys/block/${BD}/device/model 2>/dev/null): $(( $(cat /sys/block/${BD}/size) / 2048)) MB"
    fi
  done
  echo "#"
} # End of show_devices()

# Determine size of a mounted partition (in MB):
function get_part_mb_size() {
  local MYPART="${1}"
  local MYSIZE
  MYSIZE=$(df -P -BM ${MYPART} |tail -n -1 |tr -s '\t' ' ' |cut -d' ' -f2)
  echo "${MYSIZE%M}"
} # End of get_part_mb_size()

# Determine free space of a mounted partition (in MB):
function get_part_mb_free() {
  local MYPART="${1}"
  local MYSIZE
  MYSIZE=$(df -P -BM ${MYPART} |tail -n -1 |tr -s '\t' ' ' |cut -d' ' -f4)
  echo "${MYSIZE%M}"
} # End of get_part_mb_free()

# Determine requested container size in MB (allow for '%|k|K|m|M|g|G' suffix).
# Note: sizes need to be integer values! Bash arithmetics don't work for floats.
function cont_mb() {
  # Uses global variables: PARTFREE
  local MYSIZE="$1"
  case "${MYSIZE: -1}" in
     "%") MYSIZE="$(( $PARTFREE * ${MYSIZE%\%} / 100 ))" ;;
     "k") MYSIZE="$(( ${MYSIZE%k} / 1024 ))" ;;
     "K") MYSIZE="$(( ${MYSIZE%K} / 1024 ))" ;;
     "m") MYSIZE="${MYSIZE%m}" ;;
     "M") MYSIZE="${MYSIZE%M}" ;;
     "g") MYSIZE="$(( ${MYSIZE%g} * 1024 ))" ;;
     "G") MYSIZE="$(( ${MYSIZE%G} * 1024 ))" ;;
       *) MYSIZE=-1 ;;
  esac
  echo "$MYSIZE"
} # End of cont_mb()

# Expand existing encrypted container file:
function expand_container() {
  # Uses external function: cleanup
  # Uses global variables: CNTEXT, MINFREE
  # Sets global variables: CNTDEV, LODEV, PARTFREE, PARTSIZE
  local MYPART="$1" # disk partition
  local MYINC="$2"  # requested increase ('%|k|K|m|M|g|G' suffix)
  local MYFILE="$3" # full path to ${CNTEXT} containerfile
  local MYMAP=""    # Name of the device-mapped file
  local CNTIS=""    # Stores size of the container

  # Determine requested container increase in MB:
  MYINC=$(cont_mb ${MYINC})

  # Determine size of the target partition (in MB), and the free space:
  PARTSIZE=$(get_part_mb_size ${MYPART})
  PARTFREE=$(get_part_mb_free ${MYPART})

  if [ $PARTFREE -lt $(( ${MYINC} + ${MINFREE} )) ]; then
    echo "*** Free space on USB partition after file-resizing would be less than ${MINFREE} MB;"
    echo "*** Not resizing the container file!"
    cleanup
    exit 1
  fi

  if ! file ${MYFILE} |grep -q 'LUKS' ; then
    echo "*** No LUKS container: '${MYFILE}'"
    cleanup
    exit 1
  else
    echo "--- Expanding '$(basename ${MYFILE})' on '${MYPART}' with ${MYINC} MB..."
  fi

  # Append random bytes to the end of the container file:
  dd if=/dev/urandom of=${MYFILE} bs=1M count=${MYINC} oflag=append conv=notrunc 2>/dev/null

  # Setup a loopback device that we can use with or without cryptsetup:
  LODEV=$(losetup -f)
  losetup ${LODEV} ${MYFILE}

  if cryptsetup isLuks ${LODEV} ; then
    # Unlock LUKS encrypted container first:
    MYMAP=$(basename ${MYFILE} ${CNTEXT})
    CNTDEV=/dev/mapper/${MYMAP}
    echo "--- Unlocking the LUKS container requires your passphrase..."
    until cryptsetup luksOpen ${LODEV} ${MYMAP} ; do
      echo ">>> Did you type an incorrect passphrases?"
      read -p ">>> Press [ENTER] to try again or Ctrl-C to abort ..." REPLY
    done
  else
    # Use the loopmounted block device for the un-encrypted container:
    CNTDEV=${LODEV}
  fi

  # Run fsck so the filesystem is clean before we resize it:
  fsck -fvy ${CNTDEV}
  # Resize the filesystem to occupy the full new size:
  resizefs ${CNTDEV}
  # Just to be safe:
  fsck -fvy ${CNTDEV}

  # Don't forget to clean up after ourselves:
  if cryptsetup isLuks ${LODEV} ; then
    cryptsetup luksClose ${MYMAP}
  fi
  losetup -d ${LODEV} || true
} # End of expand_container()

# Uncompress the initrd based on the compression algorithm used:
function uncompressfs () {
  if $(file "${1}" | grep -qi ": gzip"); then
    gzip -cd "${1}"
  elif $(file "${1}" | grep -qi ": XZ"); then
    xz -cd "${1}"
  fi
} # End of uncompressfs ()

# Resize the filesystem on a block device:
function resizefs() {
  # Uses external function: cleanup
  local MYDEV="${1}"
  local MYFS
  local TMPMNT

  if [ -z "${MYDEV}" ]; then
    # Without arguments given, reply with list of supported fs'es:
    echo  "btrfs,ext2,ext4,f2fs,jfs,xfs"
    return
  fi

  # Determine the current filesystem for the block device:
  MYFS=$(lsblk -n -o FSTYPE ${MYDEV})
  if [ -z "${MYFS}" ]; then
    echo "*** Failed to resize filesystem on device '${MYDEV}'!"
    echo "*** No filesystem found."
    cleanup
    exit 1
  fi

  TMPMNT=$(mktemp -d -p ${TMP:=/tmp} -t alienres.XXXXXX)
  if [ ! -d $TMPMNT ]; then
    echo "*** Failed to create temporary mount for the filesystem resize!"
    cleanup
    exit 1
  else
    chmod 711 ${TMPMNT}
  fi

  # Mount the block device prior to the resize
  # (btrfs, jfs and xfs do not support offline resize):
  mount -o rw -t ${MYFS} ${MYDEV} ${TMPMNT}

  # Resize the filesystem to occupy the full new device capacity:
  case "${MYFS}" in
    btrfs) btrfs filesystem resize max ${TMPMNT}
           ;;
    ext*)  resize2fs ${MYDEV}
           ;;
    f2fs)  resize.f2fs ${MYDEV}
           ;;
    jfs)   mount -o remount,resize,rw ${TMPMNT}
           ;;
    xfs)   xfs_growfs -d ${TMPMNT}
           ;;
    *)     echo "*** Unsupported filesystem '${MYFS}'!"
           cleanup
           exit 1
           ;;
  esac

  if [ ! $? ]; then
    echo "*** Failed to resize '${MYFS}'filesystem on device '${MYDEV}'!"
    cleanup
    exit 1
  else
    # Un-mount the device again:
    sync
    umount ${TMPMNT}
    rmdir ${TMPMNT}
  fi
} # End of resizefs()


# Collect the kernel modules we need for the liveslak initrd.
# When calling this function, the old module tree must already
# have been renamed to ${OLDKVER}.prev
function collect_kmods() {
  local IMGDIR="$1"

  # Borrow (and mangle) code from Slackware's mkinitrd
  # to convert the KMODS variable into a collection of modules:
  # Sanitize the modules list first, before any further processing.
  # The awk command eliminates doubles without changing the order:
  KMODS=$(echo $KMODS |tr -s ':' '\n' |awk '!x[$0]++' |tr '\n' ':')
  KMODS=$(echo ${KMODS%:}) # Weed out a trailing ':'

  # Count number of modules
  # This INDEX number gives us an easy way to find individual
  # modules and their arguments, as well as tells us how many
  # times to run through the list
  if ! echo $KMODS | grep ':' > /dev/null ; then  # only 1 module specified
    INDEX=1
  else
    # Trim excess ':' which will screw this routine:
    KMODS=$(echo $KMODS | tr -s ':')
    INDEX=1
    while [ ! "$(echo "$KMODS" | cut -f $INDEX -d ':' )" = "" ]; do
      INDEX=$(expr $INDEX + 1)
    done
    INDEX=$(expr $INDEX - 1)      # Don't include the null value
  fi

  mkdir -p $IMGDIR/lib/modules/${KVER}

  # Wrap everything in a while loop
  i=0
  while [ $i -ne $INDEX ]; do
    i=$(( $i + 1 ))
  
    # FULL_MOD is the module plus any arguments (if any)
    # MODULE is the module name
    # ARGS is any optional arguments to be passed to the kernel
    FULL_MOD="$(echo "$KMODS" | cut -d ':' -f $i)"
    MODULE="$(echo "$FULL_MOD" | cut -d ' ' -f 1 )"
    # Test for arguments
    if echo "$FULL_MOD" | grep ' ' > /dev/null; then
      ARGS=" $(echo "$FULL_MOD" | cut -d ' ' -f 2- )"
    else
      unset ARGS
    fi

    # Get MODULE deps and prepare modprobe lines
    modprobe --dirname ${KMODDIR%%/lib/modules/${KVER}} --set-version $KVER --show-depends --ignore-install $MODULE 2>/dev/null \
      | grep "^insmod " | cut -f 2 -d ' ' | while read SRCMOD; do

      if ! grep -Eq " $(basename $SRCMOD .ko)(\.| |$)" $IMGDIR/load_kernel_modules 2>/dev/null ; then
        LINE="$(echo "modprobe -v $(basename ${SRCMOD%%.gz} .ko)" )"

        # Test to see if arguments should be passed
        # Over-ride the previously defined LINE variable if so
        if [ "$(basename $SRCMOD .ko)" = "$MODULE" ]; then
          # SRCMOD and MODULE are same, ARGS can be passed
          LINE="$LINE$ARGS"
        fi

      fi

      if ! grep -qx "$LINE" $IMGDIR/load_kernel_modules ; then
        echo "$LINE" >> $IMGDIR/load_kernel_modules
      fi

      # Try to add the module to the initrd-tree.  This should be done
      # even if it exists there already as we may have changed compilers
      # or otherwise caused the modules in the initrd-tree to need
      # replacement.
      cd ${KMODDIR}
        # Need to strip ${KMODDIR} from the start of ${SRCMOD}:
        cp -a --parents  $(echo $SRCMOD |sed 's|'${KMODDIR}'/|./|' ) $IMGDIR/lib/modules/${KVER}/ 2>/dev/null
        COPYSTAT=$?
      cd - 1>/dev/null
      if [ $COPYSTAT -eq 0 ]; then
        if [ $VERBOSE -eq 1 ]; then
          echo "OK: $SRCMOD added."
        fi
        # If a module needs firmware, copy that too
        modinfo -F firmware "$SRCMOD" | sed 's/^/\/lib\/firmware\//' |
        while read SRCFW; do
          if cp -a --parents "$SRCFW" $IMGDIR 2>/dev/null; then
            if [ $VERBOSE -eq 1 ]; then
              echo "OK: $SRCFW added."
            fi
          else
            echo "*** WARNING:  Could not find firmware \"$SRCFW\""
          fi
        done
      else
        echo "*** WARNING:  Could not find module \"$SRCMOD\""
      fi
      unset COPYSTAT

    done
  done
  # End of Slackware mkinitrd code.

  # Do we have to add network support?
  if [ $NETSUPPORT -eq 1 ]; then
    # The initrd already contains dhcpcd so we just need to add kmods:
    for NETMODPATH in ${NETMODS} ; do 
      cd ${KMODDIR}
        mkdir -p ${IMGDIR}/lib/modules/${KVER}
        cp -a --parents ${NETMODPATH} ${IMGDIR}/lib/modules/${KVER}/
      cd - 1>/dev/null
      # Prune the ones we do not need:
      for KNETRM in ${NETEXCL} ; do
        find ${IMGDIR}/lib/modules/${KVER}/${NETMODPATH} \
          -name $KNETRM -depth -exec rm -rf {} \;
      done
      # Add any dependency modules:
      for MODULE in $(find ${IMGDIR}/lib/modules/${KVER}/${NETMODPATH} -type f -exec basename {} .ko \;) ; do
        modprobe --dirname ${KMODDIR%%/lib/modules/${KVER}} --set-version $KVER --show-depends --ignore-install $MODULE 2>/dev/null |grep "^insmod " |cut -f 2 -d ' ' |while read SRCMOD; do
          if [ "$(basename $SRCMOD .ko)" != "$MODULE" ]; then
            cd ${KMODDIR}
              # Need to strip ${KMODDIR} from the start of ${SRCMOD}:
              cp -a --parents $(echo $SRCMOD |sed 's|'${KMODDIR}'/|./|' ) \
                ${IMGDIR}/lib/modules/${KVER}/
            cd - 1>/dev/null
          fi
        done
      done
    done
  fi
  # We added extra modules to the initrd, so we run depmod again:
  if [ $VERBOSE -eq 1 ]; then
    chroot ${IMGDIR} depmod $KVER
  else
    chroot ${IMGDIR} depmod $KVER 2>/dev/null
  fi
} # End of collect_kmods ()

# Read configuration data from old initrd,
# after it has been extracted into a directory:
function read_initrddir() {
  local IMGDIR="$1"
  local INITVARS="$2"
  local OLDKVER
  local OLDMODDIR
  local PREVMODDIR

  cd ${IMGDIR}

  # Retrieve the currently defined USB wait time:
  OLDWAIT=$(cat ./wait-for-root)

  # Read the values of liveslak template variables in the init script:
  for TEMPLATEVAR in ${INITVARS} ; do
    eval $(grep "^ *${TEMPLATEVAR}=" ./init |head -1)
  done

  if [ $RESTORE -eq 1 ]; then
    # Add '||true' because grep's exit code '1' may abort the script:
    PREVMODDIR=$(find ./lib/modules -type d -mindepth 1 -maxdepth 1 |grep .prev || true)
    if [ -n "${PREVMODDIR}" ] ; then
      KRESTORE=1
    else
      echo "--- No backed-up kernel modules detected in '${IMGFILE}'."
      KRESTORE=0
    fi
  fi
  if [ $UPKERNEL -eq 1 ]; then
    OLDMODDIR=$(find ./lib/modules -type d -mindepth 1 -maxdepth 1 |grep -v .prev)
    if [ $(echo ${OLDMODDIR} |wc -w) -gt 1 ] ; then
      echo "*** Multiple kernelmodule trees detected in '${IMGFILE}'."
      SUPPORTED=0
    else
      OLDKVER=$(basename "${OLDMODDIR}")
      OLDKMODDIRSIZE=$(du -sm "${OLDMODDIR}" |tr '\t' ' ' |cut -d' ' -f1)
      # Find out if the old kernel contains network support.
      # Use presence of 'devlink.ko' in the old tree to determine this,
      # but allow for a pre-set override value based on commandline preference:
      if [ -f ${OLDMODDIR}/kernel/net/core/devlink.ko ]; then
        NETSUPPORT=${NETSUPPORT:-1}
      else
        NETSUPPORT=${NETSUPPORT:-0}
      fi
    fi
  fi
} # End read_initrddir()

# Extract the initrd into a new directory and report the dirname back:
function extract_initrd() {
  local MYIMGFILE="$1"
  local MYIMGDIR=$(mktemp -d -p ${TMP:=/tmp} -t alienimg.XXXXXX)
  if [ ! -d $MYIMGDIR ]; then
    echo "*** Failed to create temporary extraction directory for the initrd!"
    cleanup
    exit 1
  else
    chmod 711 $MYIMGDIR
  fi

  cd ${MYIMGDIR}
    uncompressfs ${MYIMGFILE} 2>/dev/null \
      | cpio -i -d -m -H newc 2>/dev/null
  echo "$MYIMGDIR"
} # End of extract_initrd()
    
# Modify the extracted initrd and re-pack it:
function update_initrd() {
  local MYIMGFILE="$1"
  local MYIMGDIR="$2"
  local NEED_RECOMP=0
  local NEWMODDIR
  local OLDMODDIR
  local OLDKVER

  cd ${MYIMGDIR}
    if [ ${WAIT} -ge 0 ]; then
      if [ $WAIT != $OLDWAIT ]; then
        echo "--- Updating 'waitforroot' time from '$OLDWAIT' to '$WAIT'"
        echo ${WAIT} > wait-for-root
        NEED_RECOMP=1
      fi
    fi

    if [ $UPKERNEL -eq 1 ]; then
      OLDMODDIR=$(find ./lib/modules -type d -mindepth 1 -maxdepth 1 |grep -v .prev)
      OLDKVER=$(strings $(find ${OLDMODDIR}/kernel/ -name "*.ko*" |head -1) |grep ^vermagic |cut -d= -f2 |cut -d' ' -f1)
      rm -rf ./lib/modules/*.prev
      if [ $KBACKUP -eq 1 ]; then
        # We make one backup:
        echo "--- Making backup of kernel modules (${OLDKVER}) in initrd"
        mv -i ${OLDMODDIR} ${OLDMODDIR}.prev
      else
        echo "--- No room for backing up old kernel modules in initrd"
        rm -rf ${OLDMODDIR}
      fi
      # Add modules for the new kernel:
      echo "--- Adding new kernel modules (${KVER}) to initrd"
      collect_kmods ${MYIMGDIR}
      NEED_RECOMP=1
    elif [ $RESTORE -eq 1 -a $KRESTORE -eq 1 ]; then
      # Restore previous kernel module tree.
      # The 'read_initrddir' routine will already have checked that we have
      # one active and one .prev modules tree:
      OLDMODDIR=$(find ./lib/modules -type d -mindepth 1 -maxdepth 1 |grep .prev || true)
      NEWMODDIR=$(find ./lib/modules -type d -mindepth 1 -maxdepth 1 |grep -v .prev)
      echo "--- Restoring old kernel modules"
      rm -rf ${NEWMODDIR}
      mv ${OLDMODDIR} ${OLDMODDIR%.prev}
      NEED_RECOMP=1
    fi

    if [ -n "${LIVEINIT}" ]; then
      if ! file "${LIVEINIT}" |grep -q 'shell script' ; then
        echo "*** Not a shell script: "${LIVEINIT}"!"
        cleanup
        exit 1
      fi
      echo "--- Replacing live init script"
      cp ./init ./init.prev
      if grep -q "@LIVEMAIN@" ${LIVEINIT} ; then
        # The provided init is a liveinit template, and we need
        # to substitute the placeholders with actual values:
        parse_template ${LIVEINIT} $(pwd)/init
      else
        cat ${LIVEINIT} > ./init
      fi
      NEED_RECOMP=1
    fi

    if [ ${NEED_RECOMP} -eq 1 ]; then
      echo "--- Compressing the initrd image again"
      chmod 0755 ${MYIMGDIR}
      find . |cpio -o -H newc |$COMPR > ${MYIMGFILE}
    fi
  cd - 1>/dev/null  # End of 'cd ${MYIMGDIR}'
} # End of update_initrd()

# Accept either a kernelimage or a packagename,
# and return the path to a kernelimage:
function getpath_kernelimg () {
  local MYDATA="${*}"

  if [ -z "${MYDATA}" ]; then
     echo ""
     return
  elif [ -n "$(file "${MYDATA}" |grep -E 'x86 boot (executable|sector)')" ]; then
    # We have a kernel image:
    echo "${MYDATA}"
  else
    # We assume a Slackware package:
    # Extract the generic kernel from the package and return its filename:
    tar --wildcards -C ${KERDIR} -xf ${MYDATA} boot/vmlinuz-generic-*
    echo "$(ls --indicator-style=none ${KERDIR}/boot/vmlinuz-generic-*)"
  fi
} # End of getpath_kernelimg

# Accept either a directory containing module tree, or a packagename,
# and return the path to a module tree:
function getpath_kernelmods () {
  local MYDATA="${*}"
  local MYKVER

  if [ -z "${MYDATA}" ]; then
     echo ""
     return
  elif [ -d "${MYDATA}" ]; then
    # We have directory, assume it contains the  kernel modules:
    MYKVER=$(strings $(find ${MYDATA}/kernel/ -name "*.ko*" |head -1) |grep ^vermagic |cut -d= -f2 |cut -d' ' -f1)
    if [ -z "${MYKVER}" ]; then
      echo "*** Could not determine new kernel version from module directory!"
      cleanup
      exit 1
    fi
    mkdir -p ${KERDIR}/lib/modules/${MYKVER}
    rsync -a ${MYDATA}/ ${KERDIR}/lib/modules/${MYKVER}/
  else
    # We assume a Slackware package:
    # Extract the kernel modules from the package and return the path:
    tar -C ${KERDIR} -xf ${MYDATA} lib/modules
  fi
  cd ${KERDIR}/lib/modules/*
  pwd
} # End of getpath_kernelmods

# Determine size of a mounted partition (in MB):
function get_part_mb_size() {
  local MYSIZE
  MYSIZE=$(df -P -BM ${1} |tail -1 |tr -s '\t' ' ' |cut -d' ' -f2)
  echo "${MYSIZE%M}"
} # End of get_part_mb_size

# Determine free space of a mounted partition (in MB):
function get_part_mb_free() {
  local MYSIZE
  MYSIZE=$(df -P -BM ${1} |tail -1 |tr -s '\t' ' ' |cut -d' ' -f4)
  echo "${MYSIZE%M}"
} # End of get_part_mb_free

# Parse a liveslak template file and substitute the placeholders.
function parse_template() {
  local INFILE="$1"
  local OUTFILE="$2"

  # We expect these variables to be set before calling this function.
  # But, we do provide default values.
  DISTRO=${DISTRO:-slackware}
  VERSION=${VERSION:-1337}

  cat ${INFILE} | sed \
    -e "s/@LIVEMAIN@/${LIVEMAIN:-liveslak}/g" \
    -e "s/@MARKER@/${MARKER:-LIVESLAK}/g" \
    -e "s/@MEDIALABEL@/${MEDIALABEL:-LIVESLAK}/g" \
    -e "s/@PERSISTENCE@/${PERSISTENCE:-persistence}/g" \
    -e "s/@DARKSTAR@/${LIVE_HOSTNAME:-darkstar}/g" \
    -e "s/@LIVEUID@/${LIVEUID:-live}/g" \
    -e "s/@LIVEUIDNR@/${LIVEUIDNR:-1000}/g" \
    -e "s/@DISTRO@/$DISTRO/g" \
    -e "s/@CDISTRO@/${DISTRO^}/g" \
    -e "s/@UDISTRO@/${DISTRO^^}/g" \
    -e "s/@CORE2RAMMODS@/${CORE2RAMMODS:-"min noxbase"}/g" \
    -e "s/@VERSION@/${VERSION}/g" \
    -e "s/@KVER@/$KVER/g" \
    -e "s/@SQ_EXT_AVAIL@/${SQ_EXT_AVAIL}/g" \
    -e "s,@DEF_KBD@,${DEF_KBD},g" \
    -e "s,@DEF_LOCALE@,${DEF_LOCALE},g" \
    -e "s,@DEF_TZ@,${DEF_TZ},g" \
    > ${OUTFILE}
} # End of parse_template()

#
#  -- end of function definitions --
#

# ===========================================================================

# Parse the commandline parameters:
if [ -z "$1" ]; then
  showhelp
  exit 1
fi
while [ ! -z "$1" ]; do
  case $1 in
    -b|--nobackup)
      KBACKUP=0
      shift
      ;;
    -d|--devices)
      show_devices
      exit
      ;;
    -e|--examples)
      showexamples
      exit
      ;;
    -h|--help)
      showhelp
      exit
      ;;
    -i|--init)
      LIVEINIT="$(cd "$(dirname "$2")"; pwd)/$(basename "$2")"
      shift 2
      ;;
    -k|--kernel)
      KERNEL="$(cd "$(dirname "$2")"; pwd)/$(basename "$2")"
      shift 2
      ;;
    -m|--kmoddir)
      KMODDIR="$(cd "$(dirname "$2")"; pwd)/$(basename "$2")"
      shift 2
      ;;
    -n|--netsupport)
      NETSUPPORT=1
      shift
      ;;
    -o|--outdev)
      TARGET="$2"
      shift 2
      ;;
    -p|--persistence)
      CHANGES2SXZ=1
      shift
      ;;
    -r|--restore)
      RESTORE=1
      shift
      ;;
    -s|--scan)
      SCAN=1
      shift
      ;;
    -v|--verbose)
      VERBOSE=1
      shift
      ;;
    -w|--wait)
      WAIT="$2"
      shift 2
      ;;
     -N|--nolivemods)
      NOLIVEMODS=1
      shift
      ;;
     -x|--extend)
      EXTENSION="$2"
      shift 2
      ;;
    -X|--extendsize)
      INCSIZE="$2"
      shift 2
      ;;
    *)
      echo "*** Unknown parameter '$1'!"
      exit 1
      ;;
  esac
done

# Before we start:
if [ "$(id -u)" != "0" ]; then
  echo "*** You need to be root to run $(basename $0)."
  exit 1
fi

#
# More sanity checks:
#

# Either provide a block device, or else scan for a block device:
if [ -z "$TARGET" ]; then
  if [ $SCAN -eq 1 ]; then
    echo "--- Waiting ${SCANWAIT} seconds for a USB stick to be inserted..."
    TARGET=$(scan_devices ${SCANWAIT})
    if [ -z "$TARGET" ]; then
      echo "*** No new USB device detected during $SCANWAIT seconds scan."
      exit 1
    else
      TARGET="/dev/${TARGET}"
    fi
  else
    echo "*** You must specify the Live USB devicename (option '-o')!"
    echo "*** Alternatively, let the script scan for insertion (option '-s')!"
    exit 1
  fi
elif [ $SCAN -eq 1 ]; then
  echo "*** You can not use options '-o' and '-s' at the same time!"
  exit 1
fi

if [ ! -e /sys/block/$(basename $TARGET) ]; then
  echo "*** Not a block device: '$TARGET' !"
  show_devices
  exit 1
elif lsblk -l $TARGET |grep -w $(basename $TARGET) |grep -wq part ; then
  echo "*** You need to point to the storage device itself, not a partition ($TARGET)!"
  show_devices
  exit 1
fi

if [ -z "$KERNEL" -a -z "$KMODDIR" ]; then
  # We don't need to update the kernel/modules:
  UPKERNEL=0
else
  if [ $RESTORE -eq 1 ]; then
    echo "*** You can not use options '-k'/'-m' and '-r' at the same time!"
    exit 1
  fi
  # If we get here, we have one or both '-k' and '-m'.
  # Sanitize the input values of '-k' and '-m':
  if [ -z "$KERDIR" ]; then
    # Create a temporary extraction directory:
    mkdir -p /mnt
    KERDIR=$(mktemp -d -p /mnt -t alienker.XXXXXX)
    if [ ! -d $KERDIR ]; then
      echo "*** Failed to create temporary extraction dir for the kernel!"
      cleanup
      exit 1
    fi
  fi
  KERNEL="$(getpath_kernelimg ${KERNEL})"
  KMODDIR="$(getpath_kernelmods ${KMODDIR})"

  if [ ! -f "${KERNEL}" -o ! -d "${KMODDIR}" ]; then
    echo "*** You need to provide the path to a kernel imagefile (-k),"
    echo "*** as well as the directory containing the kernel modules (-m)!"
    cleanup
    exit 1
  else
    # Determine the new kernel version from a module,
    # rather than from a directory- or filenames:
    KVER=$(strings $(find ${KMODDIR}/kernel/ -name "*.ko*" |head -1) |grep ^vermagic |cut -d= -f2 |cut -d' ' -f1)
    if [ -z "${KVER}" ]; then
      echo "*** Could not determine kernel version from the module directory"
      cleanup
      exit 1
    fi
    UPKERNEL=1
  fi
fi

if [ -n "${LIVEINIT}" -a ! -f "${LIVEINIT}" ]; then
  echo "*** The replacement init script '${LIVEINIT}' is not a file!'"
  cleanup
  exit 1
fi

if [ -n "${EXTENSION}" ]; then
  if [ -z "${INCSIZE}" ]; then
    echo "*** LUKS container '${EXTENSION}' defined but no extension size provided!"
    echo "*** Not extending encrypted ${EXTENSION}, please use '-X' parameter."
    cleanup
    exit 1
  fi
fi

if [ $CHANGES2SXZ -eq 1 ] || [ $UPKERNEL -eq 1 ]; then
  # We need to create a module, so add squashfs to the required tools:
  REQTOOLS="${REQTOOLS} mksquashfs"
fi

# Are all the required tools present?
PROG_MISSING=""
for PROGN in ${REQTOOLS} ; do
  if ! which $PROGN 1>/dev/null 2>/dev/null ; then
    PROG_MISSING="${PROG_MISSING}--   $PROGN\n"
  fi
done
if [ ! -z "$PROG_MISSING" ] ; then
  echo "--- Required program(s) not found in search path '$PATH'!"
  echo -e ${PROG_MISSING}
  echo "--- Exiting."
  cleanup
  exit 1
fi

# We are refreshing the Live content.
# Confirm refresh:
cat <<EOT
#
# We are going to update the Live OS on this device.
# ---------------------------------------------------------------------------
# Target is - '$TARGET':
# Vendor : $(cat /sys/block/$(basename $TARGET)/device/vendor 2>/dev/null)
# Model  : $(cat /sys/block/$(basename $TARGET)/device/model 2>/dev/null)
# Size   : $(( $(cat /sys/block/$(basename $TARGET)/size) / 2048)) MB
# ---------------------------------------------------------------------------
#
# FDISK OUTPUT:
EOT

echo q |gdisk -l $TARGET 2>/dev/null | \
  while read LINE ; do echo "# $LINE" ; done

# If the user just used the scan option (-s) and did not select a task,
# we will exit the script gracefully now:
if [[ $WAIT -lt 0 && $UPKERNEL -ne 1 && $RESTORE -ne 1 && $NETSUPPORT -ne 1 && $LIVEINIT = ""  && $CHANGES2SXZ -ne 1  && $EXTENSION = "" ]]; then
  cleanup
  exit 0
else
  # We have one or more tasks to execute, allow user to back out:
  cat <<EOT
***                                                       ***
*** If this is the wrong drive, then press CONTROL-C now! ***
***                                                       ***

EOT
  read -p "Or press ENTER to continue: " JUNK
fi

# OK... the user was sure about the drive...
# Determine the three partition names independently of storage architecture:
TARGETP1=$(fdisk -l $TARGET |grep ^$TARGET |cut -d' ' -f1 |grep -E '[^0-9]1$')
TARGETP2=$(fdisk -l $TARGET |grep ^$TARGET |cut -d' ' -f1 |grep -E '[^0-9]2$')
TARGETP3=$(fdisk -l $TARGET |grep ^$TARGET |cut -d' ' -f1 |grep -E '[^0-9]3$')

# Normalize filepath:
if [ -f "${EXTENSION}" ]; then
    # Container is an actual file, so where are we mounted?
    EXTPART=$(cd "$(dirname "${EXTENSION}")" ; df --output=source . |tail -1)
    EXTMNT=$(cd "$(dirname "${EXTENSION}")" ; df --output=target . |tail -1)
    if [ "${EXTPART}" == "${TARGETP3}" ]; then
      # User already mounted the USB linux partition; remove mountpoint:
      EXTENSION="${EXTENSION#$EXTMNT}"
    fi
elif [ -n "${EXTENSION}" && "$(dirname ${EXTENSION})" == "." ]; then
  # Containerfile was provided without leading slash, add one:
  EXTENSION="/${EXTENSION}"
fi

# Create temporary mount point for the USB device:
mkdir -p /mnt
# USB mounts:
USBMNT=$(mktemp -d -p /mnt -t alienusb.XXXXXX)
if [ ! -d $USBMNT ]; then
  echo "*** Failed to create a temporary mount point for the USB device!"
  cleanup
  exit 1
else
  chmod 711 $USBMNT
fi
EFIMNT=$(mktemp -d -p /mnt -t alienefi.XXXXXX)
if [ ! -d $EFIMNT ]; then
  echo "*** Failed to create a temporary mount point for the USB device!"
  cleanup
  exit 1
else
  chmod 711 $EFIMNT
fi

# Mount the Linux partition:
mount -t auto ${TARGETP3} ${USBMNT}

# Mount the EFI partition:
mount -t vfat -o shortname=mixed ${TARGETP2} ${EFIMNT}

# Determine size of the Linux partition (in MB), and the free space:
USBPSIZE=$(get_part_mb_size ${USBMNT})
USBPFREE=$(get_part_mb_free ${USBMNT})

# Determine size of the EFI partition (in MB), and the free space:
EFIPSIZE=$(get_part_mb_size ${EFIMNT})
EFIPFREE=$(get_part_mb_free ${EFIMNT})

# Record the Slackware Live version:
OLDVERSION="$(cat ${USBMNT}/.isoversion 2>/dev/null)"
echo "--- The medium '${TARGET}' contains '${OLDVERSION}'"

# Try a write to the partition:
if touch ${USBMNT}/.rwtest 2>/dev/null && rm ${USBMNT}/.rwtest 2>/dev/null
then
  echo "--- The partition '${TARGETP3}' is writable."
else
  echo "--- Trying to remount readonly partition '${TARGETP3}' as writable..."
  mount -o remount,rw ${USBMNT}
  if [ $? -ne 0 ]; then
    echo "*** Failed to remount '${TARGETP3}' writable, unable to continue!"
    cleanup
    exit 1
  fi
fi

# Find out if the USB contains an EFI bootloader and use it:
if [ ! -f ${EFIMNT}/EFI/BOOT/boot*.efi ]; then
  EFIBOOT=0
  echo "--- Note: UEFI boot file 'bootx64.efi' or 'bootia32.efi' not found on ISO."
  echo "--- UEFI boot will not be supported"
else
  EFIBOOT=1
fi

# Record the size of the running kernel:
if  [ -f "${USBMNT}/boot/vmlinuz*" ]; then
  KIMG="$(find ${USBMNT}/boot/ -type f -name \"vmlinuz*\" |grep -v prev)"
else
  # Default liveslak kernelname:
  KIMG="${USBMNT}/boot/generic"
fi
OLDKERNELSIZE=$(du -sm "${KIMG}" |tr '\t' ' ' |cut -d' ' -f1)

# Collect data from the USB initrd:
IMGDIR="$( extract_initrd ${USBMNT}/boot/initrd.img )"
read_initrddir ${IMGDIR} "DEF_KBD DEF_LOCALE DEF_TZ DISTRO LIVE_HOSTNAME LIVEMAIN LIVEUID MARKER MEDIALABEL PERSISTENCE CORE2RAMMODS SQ_EXT_AVAIL VERSION"

# The read_initrddir routine will set SUPPORTED to '0'
# if it finds a non-standard configuration for kernel & modules:
if [ $KBACKUP -eq 1 ]; then
  if [ $SUPPORTED -ne 1 ]; then
    echo "*** ${TARGET} has an unsupported kernel configuration."
    echo "*** Exiting now."
    cleanup
    exit 1
  else
    # If free space is low, require '-b' to skip make a backup (unsafe).
    if [ $(( $USBPFREE - $OLDKMODDIRSIZE - $OLDKERNELSIZE )) -lt $MINFREE ]; then
      KBACKUP=-1
    fi
    if [ $EFIBOOT -eq 1 -a $(( $EFIPFREE - $OLDKMODDIRSIZE - $OLDKERNELSIZE )) -lt $MINFREE ]; then
      KBACKUP=-1
    fi
    if [ $KBACKUP -eq -1  ]; then
      echo "*** Not enough free space for a backup of old kernel and modules."
      echo "*** If you want to update your kerel anyway (without backup) then"
      echo "*** you have to add the parameter '-b' to the commandline."
      cleanup
      exit 1
    fi
  fi
fi

# Update the initrd with regard to USB wait time, liveinit, kernel:
update_initrd ${USBMNT}/boot/initrd.img ${IMGDIR}

# Add the new kernel modules as a squashfs module:
if [ $UPKERNEL -eq 1 ] && [ $NOLIVEMODS -eq 0 ]; then
  LIVE_MOD_SYS=$(dirname $(find ${USBMNT} -name "0099-${DISTRO}_zzzconf*.sxz" |head -1))
  LIVE_MOD_ADD=$(dirname ${LIVE_MOD_SYS})/addons
  MODNAME="0100-${DISTRO}_kernelmodules_${KVER}.sxz"
  echo "--- Creating kernelmodules addon live module '${MODNAME}'"
  rm -f ${LIVE_MOD_ADD}/${MODNAME}
  mksquashfs ${KERDIR} ${LIVE_MOD_ADD}/${MODNAME} -e boot -noappend -comp xz -b 1M
  unset LIVE_MOD_SYS LIVE_MOD_ADD MODNAME
fi

# Take care of the kernel in the Linux partition:
if [ $UPKERNEL -eq 1 ]; then
  if [ $KBACKUP -eq 1 ]; then
    # We always make one backup with the suffix ".prev":
    if [ $VERBOSE -eq 1 ]; then
      echo "--- Backing up ${KIMG} to ${USBMNT}/boot/$(basename \"${KIMG}\").prev"
    else
      echo "--- Backing up old kernel"
    fi
    mv "${KIMG}" ${USBMNT}/boot/$(basename "${KIMG}").prev
  else
    rm -rf "${KIMG}"
  fi
  # And we name our new kernel exactly as the old one:
  if [ $VERBOSE -eq 1 ]; then
    echo "--- Copying \"${KERNEL}\" to ${USBMNT}/boot/$(basename \"${KIMG}\")"
  else
      echo "--- Adding new kernel"
  fi
  cp "${KERNEL}" ${USBMNT}/boot/$(basename "${KIMG}")
elif [ $RESTORE -eq 1 -a $KRESTORE -eq 1 ]; then
  if [ $VERBOSE -eq 1 ]; then
    echo "--- Restoring ${USBMNT}/boot/$(basename \"${KIMG}\").prev to ${KIMG}"
  else
      echo "--- Restoring old kernel"
  fi
  OLDKVER=$(file "${KIMG}" |sed 's/^.*\(version [^ ]* \).*$/\1/' |cut -d' ' -f2)
  rm -f "${KIMG}"
  mv ${USBMNT}/boot/$(basename "${KIMG}").prev "${KIMG}"
  echo "--- You may remove obsolete 'addons/0100-${DISTRO}_kernelmodules_${OLDKVER}.sxz' module"
fi

if [ $EFIBOOT -eq 1 ]; then
  # Refresh the kernel/initrd on the EFI partition:
  if [ $VERBOSE -eq 1 ]; then
    rsync -rlptD  --delete -v ${USBMNT}/boot/* ${EFIMNT}/boot/
  else
    rsync -rlptD  --delete ${USBMNT}/boot/* ${EFIMNT}/boot/
  fi
  sync
fi

if [ $CHANGES2SXZ -eq 1 ]; then
  if [ ! -d /mnt/live/changes ]; then
    echo "*** No directory '/mnt/live/changes' exists!"
    echo "*** This script must be executed when running ${DISTRO^} Live Edition"
  else
    # We need to be able to write to the partition:
    mount -o remount,rw ${USBMNT}
    # Tell init to wipe the original persistence data at next boot:
    touch /mnt/live/changes/.wipe 2>/dev/null || true
    if [ ! -f /mnt/live/changes/.wipe ]; then
      echo "*** Unable to create file '/mnt/live/changes/.wipe'!"
      echo "*** Are you sure you are running ${DISTRO^} Live Edition?"
    else
      # Squash the persistence data into a Live .sxz module,
      # but only if we find the space to do so:
      CHANGESSIZE=$(du -sm /mnt/live/changes/ |tr '\t' ' ' |cut -d' ' -f1)
      if [ $(( $USBPFREE - $CHANGESSIZE )) -lt $MINFREE ]; then
        CHANGES2SXZ=-1
      fi
      if [ $CHANGES2SXZ -eq -1 ]; then
        echo "*** Not enough space to squash persistence data into a module."
        # Don't wipe persistence data on next boot!
        rm -f /mnt/live/changes/.wipe
        cleanup
        exit 1
      fi
      LIVE_MOD_SYS=$(dirname $(find ${USBMNT} -name "0099-${DISTRO}_zzzconf*.sxz" |head -1))
      LIVE_MOD_ADD=$(dirname ${LIVE_MOD_SYS})/addons
      MODNAME="0100-${DISTRO}_customchanges-$(date +%Y%m%d%H%M%S).sxz"
      echo "--- Moving current persistence data into addons module '${MODNAME}'"
      mksquashfs /mnt/live/changes ${LIVE_MOD_ADD}/${MODNAME} -noappend -comp xz -b 1M -e .wipe
    fi
  fi
fi

# Should we extend the size of a container?
if [ -n "${EXTENSION}" ]; then
  if [ "$(basename ${EXTENSION} ${CNTEXT})" == "$(basename ${EXTENSION})" ];
  then
    echo  "*** File '${EXTENSION}' does not have an '${CNTEXT}' extension!"
    cleanup
    exit 1
  fi
  # Expand existing container file:
  expand_container ${TARGETP3} ${INCSIZE} ${USBMNT}/${EXTENSION}
fi

# Unmount/remove stuff:
cleanup

# THE END

