#!/bin/bash
#
# Copyright 2015, 2016, 2017, 2019, 2020, 2021, 2022, 2023, 2024  Eric Hameleers, Eindhoven, NL
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

# Be careful:
set -e

# Limit the search path:
export PATH="/usr/sbin:/sbin:/usr/bin:/bin"

# Set to '1' if you want to ignore all warnings:
FORCE=0

# The default layout of the USB stick is:
#   partition 1 (1MB),
#   partition 2 (100 MB)
#   partition 3 (claim all free space - specified as -1 MB).
# The script allows for an amount of free space to be left at the end
# (partition 4, un-used by liveslak) in case you need this:
DEF_LAYOUT="1,100,-1,"

# The extension for containerfiles accompanying an ISO is '.icc',
# whereas the persistent USB stick created with iso2usb.sh uses '.img'.
DEFEXT=".img"
CNTEXT="${DEFEXT}"

# Default filesystem for devices/containers:
DEF_FS="ext4"
FSYS="${DEF_FS}"

# By default, we use 'slhome.img' as the name of the LUKS home containerfile.
DEF_SLHOME="slhome"
SLHOME="${DEF_SLHOME}"

# Default mount point for a LUKS container if not specified:
DEFMNT="/home"

# By default, we use 'persistence' as the name of the persistence directory,
# or 'persistence.img' as the name of the persistence container:
DEF_PERSISTENCE="persistence"
PERSISTENCE="${DEF_PERSISTENCE}"

# Default persistence type is a directory:
PERSISTTYPE="dir"

# Timeout when scanning for inserted USB device:
SCANWAIT=30

# Set to '1' if we are to scan for device insertion:
SCAN=0

# Set to '1' if the script should not ask any questions:
UNATTENDED=0

# By default do not show file operations in detail:
VERBOSE=0

# Variables to store content from an initrd we are going to refresh:
OLDPERSISTENCE=""
OLDLUKS=""
OLDVERSION=""

# Distro config variables:
BLACKLIST=""
KEYMAP=""
LIVE_HOSTNAME=""
LOAD=""
LOCALE=""
LUKSVOL=""
NOLOAD=""
RUNLEVEL=""
TWEAKS=""
TZ=""
USBPERSISTENCE=""
XKB=""

# Associative array to capture LUKSVOL definitions:
declare -A CONTAINERS=()

# Version information stored in the ISO file:
VERSION=""

# No LUKS encryption by default:
DOLUKS=0

# We are NOT refreshing existing Live content by default:
REFRESH=0

# These tools are required by the script, we will check for their existence:
REQTOOLS="blkid cpio cryptsetup extlinux fdisk find gdisk gzip isoinfo losetup lsblk lzip lzma mkdosfs sgdisk syslinux wipefs xz"

# Path to syslinux files:
if [ -d /usr/share/syslinux ]; then
  SYSLXLOC="/usr/share/syslinux"
  GPTMBRBIN=$(find $SYSLXLOC -name gptmbr.bin)
elif [ -d /usr/lib/syslinux ]; then
  SYSLXLOC="/usr/lib/syslinux"
  GPTMBRBIN=$(find $SYSLXLOC -name gptmbr.bin)
else
  # Should not happen... in this case we use what we have on the ISO
  # and hope for the best:
  SYSLXLOC="/"
  GPTMBRBIN="gptmbr.bin"
fi

# Initialize more variables:
CNTDEV=""
HLUKSSIZE=""
LUKSHOME=""
LODEV=""

# Define ahead of time, so that cleanup knows about them:
IMGDIR=""
ISOMNT=""
CNTMNT=""
USBMNT=""
US2MNT=""

# Minimim free space (in MB) we want to have left in any partition
# after we are done.
# The default value can be changed from the environment:
MINFREE=${MINFREE:-10}

# Compressor used on the initrd ("gzip" or "xz --check=crc32");
# Note that the kernel's XZ decompressor does not understand CRC64:
COMPR="xz --check=crc32"

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
  if [ $DOLUKS -eq 1 -a -n "$CNTDEV" ]; then
    # In case of failure, only the most recent device should still be open:
    if mount |grep -q ${CNTDEV} ; then
      umount -f ${CNTDEV}
      cryptsetup luksClose $(basename ${CNTDEV})
      losetup -d ${LODEV}
    fi
  fi
  [ -n "${ISOMNT}" ] && ( umount -f ${ISOMNT} 2>/dev/null; rmdir $ISOMNT 2>/dev/null )
  [ -n "${CNTMNT}" ] && ( umount -f ${CNTMNT} 2>/dev/null; rmdir $CNTMNT 2>/dev/null )
  [ -n "${USBMNT}" ] && ( umount -f ${USBMNT} 2>/dev/null; rmdir $USBMNT 2>/dev/null )
  [ -n "${US2MNT}" ] && ( umount -f ${US2MNT} 2>/dev/null; rmdir $US2MNT 2>/dev/null )
  [ -n "${IMGDIR}" ] && ( rm -rf $IMGDIR )
  set -e
} # End of cleanup()
trap 'echo "*** $0 FAILED at line $LINENO ***"; cleanup; exit 1' ERR INT TERM

function showhelp() {
cat <<EOT
#
# Purpose: to transfer the content of Slackware's Live ISO image
#   to a standard USB thumb drive (or some other kind of external storage)
#   and thus create a Slackware Live USB media. 
#
# WARNING: Your USB thumb drive may contain data!
# If you are not using the refresh option '-r' then this data will be *erased* !
#
# $(basename $0) accepts the following parameters:
#   -c|--crypt size|perc       Add LUKS encrypted $DEFMNT ; parameter is the
#                              requested size of the container in kB, MB, GB,
#                              or as a percentage of free space
#                              (integer numbers only).
#                              Examples: '-c 125M', '-c 2G', '-c 20%'.
#   -d|--devices               List removable devices on this computer.
#   -f|--force                 Ignore most warnings (except the back-out).
#   -h|--help                  This help.
#   -i|--infile <filename>     Full path to the ISO image file.
#   -l|--lukshome <name>       Custom path to the containerfile for your LUKS
#                              encrypted $DEFMNT ($SLHOME by default).
#   -o|--outdev <filename>     The device name of your USB drive.
#   -p|--persistence <name>    Custom path to the 'persistence' directory
#                              or containerfile ($PERSISTENCE by default).
#   -r|--refresh               Refresh the USB stick with the ISO content.
#                              No formatting, do not touch user content.
#   -s|--scan                  Scan for insertion of new USB device instead of
#                              providing a devicename (using option '-o').
#   -u|--unattended            Do not ask any questions.
#   -v|--verbose               Show verbose messages.
#   -y|--layout <x,x,x,x>      Specify partition layout and sizes (in MB).
#                              Default values: '$DEF_LAYOUT' for 3 partitions,
#                              the '-1' value for partition 3 meaning
#                              'use all remaining space',
#                              and an empty 4th value means 'do not reserve
#                              free space for a custom 4th partition'.
#   -C|--cryptpersistfile size|perc
#                              Use a LUKS-encrypted 'persistence' file instead
#                              of a directory (for use on FAT filesystem)
#                              Format for size/percentage is the same
#                              as for the '-c' parameter.
#   -F|--filesystem <fs>       Specify filesystem to create when formatting
#                              devices/containers. Defaults to '${DEF_FS}',
#                              Choices are $(createfs).
#                              Note that the linux partition will always be
#                              formatted as 'ext4' because extlinux is used
#                              as the BIOS bootloader.
#   -P|--persistfile           Use a 'persistence' container file instead of
#                              a directory (for use on FAT filesystem).
#                              Persistent data will not be migrated
#                              when switching from directory to container file.
#
# Examples:
#
# Transfer the ISO content to a USB stick, overwriting existing content:
#   $(basename $0) -i ~/download/slackware64-live-15.0.iso -o /dev/sdX
# Transfer ISO content to a eMMC device and create a 750MB encrypted $DEFMNT :
#   $(basename $0) -i slackware64-live-xfce-current.iso -o /dev/mmcblkX -c 750M
# Use a custom partition layout, creating a 4 GB un-used partition at the end:
#   $(basename $0) -i slackware-live-current.iso -o /dev/sdX -y 1,200,-1,4096
#
EOT
} # End of showhelp()

# Create a filesystem on a partition with optional label:
function createfs () {
  MYDEV="${1}"
  MYFS="${2:-'ext4'}"
  MYLABEL="${3}"

  if [ -z "${MYDEV}" ]; then
    # Without arguments given, reply with list of supported fs'es:
    echo  "btrfs,ext2,ext4,f2fs,jfs,xfs"
    return
  fi

  if [ -n "${MYLABEL}" ]; then
    case "${MYFS}" in
    fs2s) MYLABEL="-l ${MYLABEL}" ;;
    *)    MYLABEL="-L ${MYLABEL}" ;;
    esac
  fi

  case "${MYFS}" in
    btrfs) mkfs.btrfs -f -d single -m single ${MYLABEL} ${MYDEV}
           ;;
    ext2)  mkfs.ext2 -F -F ${MYLABEL} ${MYDEV}
           # Tune the ext2 filesystem:
           tune2fs -m 0 -c 0 -i 0 ${MYDEV}
           ;;
    ext4)  mkfs.ext4 -F -F ${MYLABEL} ${MYDEV}
           # Tune the ext4 filesystem:
           tune2fs -m 0 -c 0 -i 0 ${MYDEV}
           ;;
    f2fs)  mkfs.f2fs ${MYLABEL} -f ${MYDEV}
           ;;
    jfs)   mkfs.jfs -q ${MYDEV}
           ;;
    xfs)   mkfs.xfs -f ${MYDEV}
           ;;
    *)     echo "*** Unsupported filesystem '${MYFS}'!"; exit 1
           ;;
  esac
} # End of createfs()

# Uncompress the initrd based on the compression algorithm used:
function uncompressfs () {
  local IMGFILE="$1"
  # Content is streamed to STDOUT:
  if $(file "${IMGFILE}" | grep -qi ": gzip"); then
    gzip -cd "${IMGFILE}"
  elif $(file "${IMGFILE}" | grep -qi ": XZ"); then
    xz -cd "${IMGFILE}"
  elif $(file "${IMGFILE}" | grep -qi ": LZMA"); then
    lzma -cd "${IMGFILE}"
  elif $(file "${IMGFILE}" | grep -qi ": lzip"); then
    lzip -cd "${IMGFILE}"
  fi
} # End of uncompressfs()

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
  echo "#"
  echo "# Removable devices detected on this computer:"
  for BD in ${MYDATA} ; do
    if [ $(cat /sys/block/${BD}/removable) -eq 1 ]; then
      echo "# /dev/${BD} : $(cat /sys/block/${BD}/device/vendor 2>/dev/null) $(cat /sys/block/${BD}/device/model 2>/dev/null): $(( $(cat /sys/block/${BD}/size) / 2048)) MB"
    fi
  done
  echo "#"
} # End of show_devices()

# Read variables from distro config (/liveslak/slackware_os.cfg)
function read_distroconfig() {
  # Sets global variables: BLACKLIST KEYMAP LIVE_HOSTNAME LOAD LOCALE LUKSVOL NO LOAD RUNLEVEL TWEAKS TZ USBPERSISTENCE XKB
  local MYDISTROCFG="${1}"
  local LIVEPARM
  # Read Distro customization from the "@DISTRO@_os.cfg" file if it exists:
  if [ -f "${MYDISTROCFG}" ]; then
    for LIVEPARM in \
      BLACKLIST KEYMAP LIVE_HOSTNAME LOAD LOCALE LUKSVOL \
      NOLOAD RUNLEVEL TWEAKS TZ USBPERSISTENCE XKB ;
    do
      # Read values from disk only if the variable has not been set yet:
      if [ -z "$(eval echo \$${LIVEPARM})" ]; then
        eval $(grep -w ^${LIVEPARM} ${MYDISTROCFG})
      fi
    done
  else
    echo "-- No distro configuration (${MYDISTROCFG}) found."
  fi
} # End of read_distroconfig()

# Write variables to distro config (/liveslak/slackware_os.cfg)
function write_distroconfig() {
  # Uses global arrays: CONTAINERS
  # Uses global variables: DISTRO, VERSION
  # Uses global variables: BLACKLIST KEYMAP LIVE_HOSTNAME LOAD LOCALE LUKSVOL NOLOAD RUNLEVEL TWEAKS TZ USBPERSISTENCE XKB
  local MYDISTROCFG="${1}"
  local MYPART="${2}"

  if [ ${#CONTAINERS[@]} -gt 0 ]; then
    # CONTAINERS array is non-empty; (re-)assemble the LUKSVOL variable.
    # First zap the LUKSVOL value:
    LUKSVOL=""
    # Write the CONTAINERS array back into LUKSVOL in the correct format:
    for _mount in "${!CONTAINERS[@]}"; do
      LUKSVOL="${LUKSVOL}${CONTAINERS[$_mount]}:${_mount},"
    done
    # Remove the trailing ',':
    LUKSVOL="${LUKSVOL::-1}"
  fi

  # Preserve user additions:
  if [ -f ${MYDISTROCFG} ]; then
    cat ${MYDISTROCFG} \
      | grep -Ev '(^# --|^BLACKLIST=|^KEYMAP=|^LIVE_HOSTNAME=|^LOAD LOCALE=|^LUKSVOL=|^NOLOAD=|^RUNLEVEL=|^TWEAKS=|^TZ=|^USBPERSISTENCE=|^XKB=)' \
      > ${MYDISTROCFG}.orig \
      || true # an empty 'grep' result has exit code 1, terminating the script.
  fi

  # Write updated customization into the Distro cfg file:
  echo "# -- Liveslak ${DISTRO} configuration file for ${VERSION}" > ${MYDISTROCFG} 2>/dev/null
  echo "# -- Generated by $(basename $0) on $(date +%Y%m%d_%H%M)" >> ${MYDISTROCFG} 2>/dev/null
  if [ $? -ne 0 ]; then
    echo "***  USB media ${MYPART} read-only, cannot write config file."
  else
    for LIVEPARM in \
      BLACKLIST KEYMAP LIVE_HOSTNAME LOAD LOCALE LUKSVOL \
      NOLOAD RUNLEVEL TWEAKS TZ USBPERSISTENCE XKB ;
    do
      if [ -n "$(eval echo \$$LIVEPARM)" ]; then
        echo $LIVEPARM=$(eval echo \$$LIVEPARM) >> ${MYDISTROCFG}
      fi 
    done
    if [ -f ${MYDISTROCFG}.orig ]; then
      echo "# -- Preserved user additions -- #" >> ${MYDISTROCFG}
      cat ${MYDISTROCFG}.orig >> ${MYDISTROCFG}
      rm -f ${MYDISTROCFG}.orig
    fi
  fi
} # End of write_distroconfig()

# Update distro configuration variables (and translate LUKSVOL -> CONTAINERS)
# before writing to disk:
function update_distroconfig() {
  # Uses global arrays: CONTAINERS
  # Uses global variables: DISTRO
  # Uses global variables: BLACKLIST KEYMAP LIVE_HOSTNAME LOAD LOCALE LUKSVOL NOLOAD RUNLEVEL TWEAKS TZ USBPERSISTENCE XKB

  if [ $REFRESH -eq 1 ]; then
    echo "--- Refreshing ${DISTRO} Live configuration..."
    if [ -n "$OLDLUKS" ]; then
      echo "--- Detected LUKS container configuration:"
      echo "$OLDLUKS" | sed 's/^/    /'
    fi
    LUKSVOL="$OLDLUKS"

    if [ "${PERSISTENCE}" != "${DEF_PERSISTENCE}" ]; then
      # If the user specified a nonstandard persistence, use that:
      echo "--- Update persistence from '$OLDPERSISTENCE' to '$PERSISTENCE'"
      USBPERSISTENCE="${PERSISTENCE}"
    elif [ "${PERSISTENCE}" != "${OLDPERSISTENCE}" ]; then
      # The user did not specify persistence, re-use the retrieved value:
      echo "--- Re-use previous '$OLDPERSISTENCE' for persistence"
      USBPERSISTENCE="${OLDPERSISTENCE}"
      PERSISTENCE="${OLDPERSISTENCE}"
    fi
  else
    if [ "${PERSISTENCE}" != "${DEF_PERSISTENCE}" ]; then
      # If the user specified a nonstandard persistence, use that:
      echo "--- Update persistence from '$DEF_PERSISTENCE' to '$PERSISTENCE'"
      USBPERSISTENCE="${PERSISTENCE}"
    fi
  fi

  # Determine where in LUKSVOL the /home (aka DEFMNT) is defined (or not).
  # The LUKSVOL value looks like:
  # "/path/to/cntner1:/mountpoint1,[/path/to/cntner2:/mountpoint2,[...]]"
  # Break down the LUKSVOL value into container/mountpoint combo's:
  if [ -n "$LUKSVOL" ]; then
    _container=""
    _mount=""
    for _luksvol in $(echo $LUKSVOL |tr ',' ' '); do
      _container="$(echo $_luksvol |cut -d: -f1)"
      _mount="$(echo $_luksvol |cut -d: -f2)"
      if [ "$_mount" == "$_container" ]; then
        # No optional mount point specified, so we use the default:
        CONTAINERS["${DEFMNT}"]="$_container"
      else
        CONTAINERS["$_mount"]="$_container"
      fi
    done
  fi

  if [ $DOLUKS -eq 1 ]; then
    # Check if we already have a container mounted on DEFMNT:
    if [ -v 'CONTAINERS["${DEFMNT}"]' ] && [ "${LUKSHOME}" != "${CONTAINERS["${DEFMNT}"]}" ]; then
      echo "*** On-disk configuration defines an existing container"
      echo "*** '${CONTAINERS["${DEFMNT}"]}', to be mounted at '${DEFMNT}'."
      echo "*** This is different from your parameter '-l ${LUKSHOME}'."
      if [ $FORCE -eq 0 ]; then
        echo "*** Not creating new encrypted container for '${DEFMNT}',"
        echo "*** please fix LUKSVOL in '/${LIVEMAIN}/${DISTRO}_os.cfg',"
        echo "*** or supply the correct value for the '-l' parameter"
        echo "*** ... or add parameter '-f' to enforce this action!"
      else
        echo "--- Accepting mountpoint '${DEFMNT}' for new encrypted container '${LUKSHOME}',"
        echo "--- and changing mountpoint for '${CONTAINERS["${DEFMNT}"]}' to '${DEFMNT}_prev'."
        CONTAINERS["${DEFMNT}_prev"]="${CONTAINERS["${DEFMNT}"]}"
        CONTAINERS["${DEFMNT}"]="${LUKSHOME}"
      fi
    fi
  fi
} # End of update_distroconfig()

# Read configuration data from the initrd inside the ISO,
# after it has been extracted into a directory:
function read_initrddir() {
  local IMGDIR="$1"
  local INITVARS="${2:-'DISTRO LIVEMAIN MARKER MEDIALABEL'}"
  cd ${IMGDIR}

  # Retrieve the currently defined LUKS device:
  OLDLUKS=$(cat ./luksdev)

  # Retrieve the currently defined name for persistence:
  OLDPERSISTENCE=$(cat ./init |grep "^PERSISTENCE" |cut -d '"' -f2)

  # Read the values of liveslak template variables in the init script:
  for TEMPLATEVAR in ${INITVARS} ; do
    eval $(grep "^ *${TEMPLATEVAR}=" ./init |head -1)
  done
} # End of read_initrddir()

# Extract the initrd:
function extract_initrd() {
  local IMGFILE="$1"
  local IMGDIR=$(mktemp -d -p /tmp -t alienimg.XXXXXX)
  if [ ! -d $IMGDIR ]; then
    echo "*** Failed to create temporary extraction directory for the initrd!"
    cleanup
    exit 1
  else
    chmod 711 $IMGDIR
  fi
  cd ${IMGDIR}
    uncompressfs ${IMGFILE} 2>/dev/null \
      | cpio -i -d -m -H newc 2>/dev/null
  echo "$IMGDIR"
} # End of extract_initrd()

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

# Determine requested container size in MB (allow for '%|k|K|m|M|g|G' suffix):
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

# Create a container file in the empty space of the partition
function create_container() {
  # Uses external function: cleanup
  # Uses global arrays: CONTAINERS
  # Uses global variables: CNTEXT, DEFMNT, FSYS, ISOMNT, MINFREE
  # Sets global variables: CNTDEV, CNTMNT, LODEV, PARTFREE, PARTSIZE

  local CNTPART=$1 # partition containing the ISO
  local CNTSIZE=$2 # size of the container file to create
  local CNTFILE=$3 # ${CNTEXT} filename with full path
  local CNTENCR=$4 # 'none' or 'luks'
  local CNTUSED=$5 # '/home' or 'persistence'
  local MYMAP
  local MYMNT

  # If containerfile extension is missing, add it now:
  if [ "${CNTFILE%${CNTEXT}}" == "${CNTFILE}" ]; then
    CNTFILE="${CNTFILE}${CNTEXT}"
  fi

  # Create a container file or re-use previously created one:
  if [ -f ${CNTFILE} ]; then
    # Where are we mounted?
    MYMNT=$(cd "$(dirname "${CNTFILE}")" ; df --output=target . |tail -1)
    CNTSIZE=$(( $(du -sk ${CNTFILE} |tr '\t' ' ' |cut -f1 -d' ') / 1024 ))
    echo "--- Keeping existing '${CNTFILE#${MYMNT}}' (size ${CNTSIZE} MB)."
    return
  fi

  # Determine size of the target partition (in MB), and the free space:
  PARTSIZE=$(get_part_mb_size ${CNTPART})
  PARTFREE=$(get_part_mb_free ${CNTPART})

  if [ $PARTFREE -lt ${MINFREE} ]; then
    echo "*** Free space on USB partition is less than ${MINFREE} MB;"
    echo "*** Not creating a container file!"
    cleanup
    exit 1
  fi

  # Determine requested container size in MB (allow for '%|k|K|m|M|g|G' suffix):
  CNTSIZE=$(cont_mb ${CNTSIZE})

  if [ $CNTSIZE -le 0 ]; then
    echo "*** Container size must be larger than ZERO!"
    echo "*** Check your '-c' commandline parameter."
    cleanup
    exit 1
  elif [ $CNTSIZE -ge $PARTFREE ]; then
    echo "*** Not enough free space for container file!"
    echo "*** Check your '-c' commandline parameter."
    cleanup
    exit 1
  fi

  echo "--- Creating ${CNTSIZE} MB container file using 'dd if=/dev/urandom', patience please..."
  mkdir -p $(dirname "${CNTFILE}")
  if [ $? ]; then
    # Create a sparse file (not allocating any space yet):
    dd of=${CNTFILE} bs=1M count=0 seek=$CNTSIZE 2>/dev/null
  else
    echo "*** Failed to create directory for the container file!"
    cleanup
    exit 1
  fi

  # Setup a loopback device that we can use with cryptsetup:
  LODEV=$(losetup -f)
  losetup $LODEV ${CNTFILE}
  MYMAP=$(basename ${CNTFILE} ${CNTEXT})
  if [ "${CNTENCR}" = "luks" ]; then
    # Format the loop device with LUKS:
    echo "--- Encrypting the container file with LUKS via '${LODEV}'"
    echo "--- This takes SOME time, please be patient..."
    echo "--- enter 'YES' and a passphrase:"
    until cryptsetup -y luksFormat $LODEV ; do
      echo ">>> Did you type two different passphrases?"
      read -p ">>> Press [ENTER] to try again or Ctrl-C to abort ..." REPLY 
    done
    # Unlock the LUKS encrypted container:
    echo "--- Unlocking the LUKS container requires your passphrase again..."
    until cryptsetup luksOpen $LODEV ${MYMAP} ; do
      echo ">>> Did you type an incorrect passphrases?"
      read -p ">>> Press [ENTER] to try again or Ctrl-C to abort ..." REPLY 
    done
    CNTDEV=/dev/mapper/${MYMAP}
    # Now we allocate blocks for the LUKS device. We write encrypted zeroes,
    # so that the file looks randomly filled from the outside.
    # Take care not to write more bytes than the internal size of the container:
    echo "--- Writing ${CNTSIZE} MB of random data to encrypted container; takes LONG time..."
    CNTIS=$(( $(lsblk -b -n -o SIZE  $(readlink -f ${CNTDEV})) / 512))
    dd if=/dev/zero of=${CNTDEV} bs=512 count=${CNTIS} status=progress || true
  else
    # Un-encrypted container files remain sparse.
    CNTDEV=$LODEV
  fi

  # Format the now available block device with a linux fs:
  createfs ${CNTDEV} ${FSYS}

  if [ "${CNTUSED}" != "persistence" ]; then
    # Create a mount point for the unlocked container:
    CNTMNT=$(mktemp -d -p /mnt -t aliencnt.XXXXXX)
    if [ ! -d $CNTMNT ]; then
      echo "*** Failed to create temporary mount point for the LUKS container!"
      cleanup
      exit 1
    else
      chmod 711 $CNTMNT
    fi
    # Copy the original /home (or whatever mount) content into the container:
    echo "--- Copying '${CNTUSED}' from LiveOS to container..."
    HOMESRC=$(find ${ISOMNT} -name "0099-slackware_zzzconf*" |tail -1)
    mount ${CNTDEV} ${CNTMNT}
    unsquashfs -n -d ${CNTMNT}/temp ${HOMESRC} ${CNTUSED}
    mv ${CNTMNT}/temp/${CNTUSED}/* ${CNTMNT}/
    rm -rf ${CNTMNT}/temp
    umount ${CNTDEV}
  fi

  if [ "${CNTENCR}" = "luks" ]; then
    # Update CONTAINERS using the path to the container in the USB filesystem.
    # First remove any redundant slashes:
    CNTFILE=$(echo ${CNTFILE} |tr -s '/')
    # Determine the container mount point and remove that from the path:
    MYMNT=$(cd "$(dirname "${CNTFILE}")" ; df --output=target . |tail -1)
    CONTAINERS["${CNTUSED}"]="${CNTFILE#${MYMNT}}"
    # Don't forget to clean up after ourselves:
    cryptsetup luksClose ${MYMAP}
  fi
  losetup -d ${LODEV} || true
} # End of create_container() {

#
#  -- end of function definitions --
#

# Parse the commandline parameters:
if [ -z "$1" ]; then
  showhelp
  exit 1
fi
while [ ! -z "$1" ]; do
  case $1 in
    -c|--crypt)
      HLUKSSIZE="$2"
      DOLUKS=1
      # Needs unsquashfs to extract the /home
      REQTOOLS="${REQTOOLS} unsquashfs zstd"
      shift 2
      ;;
    -d|--devices)
      show_devices
      exit
      ;;
    -f|--force)
      FORCE=1
      shift
      ;;
    -h|--help)
      showhelp
      exit
      ;;
    -i|--infile)
      SLISO="$(cd $(dirname $2); pwd)/$(basename $2)"
      shift 2
      ;;
    -l|--lukshome)
      SLHOME="$2"
      shift 2
      ;;
    -o|--outdev)
      TARGET="$2"
      shift 2
      ;;
    -p|--persistence)
      PERSISTENCE="$2"
      shift 2
      ;;
    -r|--refresh)
      REFRESH=1
      shift
      ;;
    -s|--scan)
      SCAN=1
      shift
      ;;
    -u|--unattended)
      UNATTENDED=1
      shift
      ;;
    -v|--verbose)
      VERBOSE=1
      shift
      ;;
    -y|--layout)
      LAYOUT="$2"
      shift 2
      ;;
    -C|--cryptpersistfile)
      DOLUKS=1
      PLUKSSIZE="$2"
      PERSISTTYPE="file"
      shift 2
      ;;
    -F|--filesystem)
      FSYS="$2"
      shift 2
      ;;
    -P|--persistfile)
      PERSISTTYPE="file"
      shift
      ;;
    *)
      echo "*** Unknown parameter '$1'!"
      exit 1
      ;;
  esac
done

# Before we start:
if [ "$(id -u)" != "0" -a $FORCE -eq 0 ]; then
  echo "*** You need to be root to run $(basename $0)."
  exit 1
fi

# More sanity checks:
if [ -z "$SLISO" ]; then
  echo "*** You must specify the Live ISO filename (option '-i')!"
  exit 1
fi

# Either provide a block device, or else scan for a block device:
if [ -z "$TARGET" ]; then
  if [ $SCAN -eq 1 ]; then
    echo "-- Waiting  ${SCANWAIT} seconds for a USB stick to be inserted..."
    TARGET=$(scan_devices ${SCANWAIT})
    if [ -z "$TARGET" ]; then
      echo "*** No new USB device detected during $SCANWAIT seconds scan."
      exit 1
    else
      TARGET="/dev/${TARGET}"
    fi
  else
    echo "*** You must specify the Live USB devicename (option '-o')!"
    exit 1
  fi
elif [ $SCAN -eq 1 ]; then
  echo "*** You can not use options '-o' and '-s' at the same time!"
  exit 1
fi

if [ $FORCE -eq 0 -a ! -f "$SLISO" ]; then
  echo "*** This is not a useable file: '$SLISO' !"
  exit 1
fi

if [ "${HLUKSSIZE%.*}" != "${HLUKSSIZE}" ] ; then
  echo "*** Integer value required in '-c $HLUKSSIZE' !"
  exit 1
fi

if [ "${PLUKSSIZE%.*}" != "${PLUKSSIZE}" ] ; then
  echo "*** Integer value required in '-C $PLUKSSIZE' !"
  exit 1
fi

if [ $FORCE -eq 0 ]; then
  if [ ! -e /sys/block/$(basename $TARGET) ]; then
    echo "*** Not a block device: '$TARGET' !"
    show_devices
    exit 1
  elif lsblk -l $TARGET |grep -w $(basename $TARGET) |grep -wq part ; then
    echo "*** You need to point to the storage device itself, not a partition ($TARGET)!"
    show_devices
    exit 1
  fi
fi

# Add required filesystem tools:
REQTOOLS="${REQTOOLS} mkfs.${FSYS}"

# Are all the required not-so-common add-on tools present?
PROG_MISSING=""
for PROGN in ${REQTOOLS} ; do
  if ! which $PROGN 1>/dev/null 2>/dev/null ; then
    PROG_MISSING="${PROG_MISSING}--   $PROGN\n"
  fi
done
if [ ! -z "$PROG_MISSING" ] ; then
  echo "-- Required program(s) not found in search path '$PATH'!"
  echo -e ${PROG_MISSING}
  if echo ${PROG_MISSING} |grep -wq zstd ; then
    echo "-- Note that the 'zstd' program is missing which means"
    echo "-- unsquashfs is not linking against it."
    echo "-- Install the zstd and squashf-stools packages for zstd support."
  fi
  echo "-- Exiting."
  exit 1
fi

# Retrieve the version information from the ISO:
VERSION=$(isoinfo -d -i "${SLISO}" 2>/dev/null |grep Application |cut -d: -f2-)

if [ $REFRESH -eq 0 ]; then
  # We are creating a USB stick from scratch,
  # i.e. not refreshing the Live content.
  # Confirm wipe:
  cat <<EOT
#
# We are going to format this device (erase all data) - '$TARGET':
EOT
else
  # We are refreshing the Live content.
  # Confirm refresh:
  cat <<EOT
#
# We are going to refresh the Live OS on this device with '$VERSION'.
# Target is - '$TARGET':
EOT
fi
  # Continue with the common text message:
  cat <<EOT
# ---------------------------------------------------------------------------
# Vendor : $(cat /sys/block/$(basename $TARGET)/device/vendor 2>/dev/null)
# Model  : $(cat /sys/block/$(basename $TARGET)/device/model 2>/dev/null)
# Size   : $(( $(cat /sys/block/$(basename $TARGET)/size) / 2048)) MB
# ---------------------------------------------------------------------------
#
# FDISK OUTPUT:
EOT

  echo q |gdisk -l $TARGET 2>/dev/null | \
    while read LINE ; do echo "# $LINE" ; done

  if [ $UNATTENDED -eq 0 ]; then
    cat <<EOT

***                                                       ***
*** If this is the wrong drive, then press CONTROL-C now! ***
***                                                       ***

EOT
    read -p "Or press ENTER to continue: " JUNK
    # OK... the user was sure about the drive...
  fi

if [ $REFRESH -eq 0 ]; then
  # Continue with the wipe/partitioning/formatting.

  # Get the LABEL used for the ISO:
  LIVELABEL=$(blkid -s LABEL -o value "${SLISO}")

  # Use sgdisk to wipe and then setup the USB device:
  # - 1 MB BIOS boot partition
  # - 100 MB EFI system partition
  # - Let Slackware have the rest
  # - Make the Linux partition "legacy BIOS bootable"
  # Make sure that there is no MBR nor a partition table anymore:
  dd if=/dev/zero of=$TARGET bs=512 count=1 conv=notrunc

  # We have to use wipefs before sgdisk or else traces of an old 'cp' or 'dd'
  # of a Live ISO image to the device will not be erased.
  # The sgdisk wipe command is allowed to have non-zero exit code:
  wipefs -af $TARGET
  sgdisk -og $TARGET || true

  # After the wipe, get the value of the last usable sector:
  ENDSECT=$(sgdisk -E $TARGET)

  # Calculate partition layout in MB.
  # User may specify custom non-zero sizes, also for keeping some free space:
  if [ -z "$LAYOUT" ]; then LAYOUT=${DEF_LAYOUT}; fi

  # Let's first determine whether the user wanted space for a 4th partition:
  LP4=$(echo $LAYOUT |cut -d, -f4)
  if [ -z "$LP4" ]; then LP4=$(echo $DEF_LAYOUT |cut -d, -f4) ; fi

  LP1=$(echo $LAYOUT |cut -d, -f1)
  if [ -z "$LP1" ]; then LP1=$(echo $DEF_LAYOUT |cut -d, -f1) ; fi
  LP1_START=2048
  LP1_END=$(( ${LP1_START} + ( ${LP1} *2048 ) - 1 ))

  LP2=$(echo $LAYOUT |cut -d, -f2)
  if [ -z "$LP2" ]; then LP2=$(echo $DEF_LAYOUT |cut -d, -f2) ; fi
  LP2_START=$(( ${LP1_END} + 1 ))
  LP2_END=$(( ${LP2_START} + ( $LP2 *2048 ) - 1 ))

  LP3=$(echo $LAYOUT |cut -d, -f3)
  if [ -z "$LP3" ]; then LP3=$(echo $DEF_LAYOUT |cut -d, -f3) ; fi
  LP3_START=$(( ${LP2_END} + 1 ))
  # The end of partition 3 depends on both values of LP3 and LP4:
  if [ -n "${LP4}" ] && [ ${LP4} -gt 0 ]; then
    LP3_END=$(( $ENDSECT - ( $LP4 * 2048 ) -1 ))
  elif [ -n "${LP3}" ] && [ ${LP3} -gt 0 ]; then
    LP3_END=$(( ${LP3_START} + ( $LP3 *2048 ) - 1 ))
  else
    # Give all remaining space to partition 3:
    LP3_END=0
  fi

  # END calculating partition layout in MB.

  # Setup the disk partitions:
  sgdisk \
    -n 1:${LP1_START}:${LP1_END} -c 1:"BIOS Boot Partition" -t 1:ef02 \
    -n 2:${LP2_START}:${LP2_END} -c 2:"EFI System Partition" -t 2:ef00 \
    -n 3:${LP3_START}:${LP3_END} -c 3:"Slackware Linux" -t 3:8300 \
    $TARGET
  sgdisk -A 3:set:2 $TARGET
  # Show what we did to the USB stick:
  sgdisk -p -A 3:show $TARGET

  # Determine partition names independently of storage architecture:
  TARGETP1=$(fdisk -l $TARGET |grep ^$TARGET |cut -d' ' -f1 |grep -E '[^0-9]1$')
  TARGETP2=$(fdisk -l $TARGET |grep ^$TARGET |cut -d' ' -f1 |grep -E '[^0-9]2$')
  TARGETP3=$(fdisk -l $TARGET |grep ^$TARGET |cut -d' ' -f1 |grep -E '[^0-9]3$')

  # Create filesystems:
  # Not enough clusters for a 32 bit FAT:
  mkdosfs -s 2 -n "DOS" ${TARGETP1}
  mkdosfs -F32 -s 2 -n "ESP" ${TARGETP2}
  # KDE tends to automount.. so try an umount:
  if mount |grep -qw ${TARGETP3} ; then
    umount ${TARGETP3} || true
  fi
  # We use extlinux to boot the stick, so other filesystems are not accepted:
  createfs ${TARGETP3} ext4 "${LIVELABEL}"
  # http://www.syslinux.org/wiki/index.php?title=Filesystem
  # As of Syslinux 6.03, "pure 64-bits" compression/encryption is unsupported.
  # Modern mke2fs creates file systems with the metadata_csum and 64bit
  # features enabled by default.
  # Explicitly disable 64bit feature in the mke2fs command with '-O ^64bit';
  # otherwise, the syslinux bootloader (>= 6.03) will fail.
  # Note: older 32bit OS-es will trip over the '^64bit' feature so be gentle.
  UNWANTED_FEAT=""
  if tune2fs -O ^64bit ${TARGETP3} 1>/dev/null 2>/dev/null ; then
    UNWANTED_FEAT="^64bit,"
  fi
  # Grub 2.0.6 stumbles over metadata_csum_seed which is enabled by default
  # since e2fsprogs 1.47.0, so let's disable that too:
  if tune2fs -O ^metadata_csum_seed ${TARGETP3} 1>/dev/null 2>/dev/null ; then
    UNWANTED_FEAT="${UNWANTED_FEAT}^metadata_csum_seed,"
  fi
  if [ -n "${UNWANTED_FEAT}" ]; then
    # We found unwanted feature(s), get rid of trailing comma:
    UNWANTED_FEAT="-O ${UNWANTED_FEAT::-1}"
  fi
  tune2fs -c 0 -i 0 -m 0 ${UNWANTED_FEAT} ${TARGETP3}
else
  # Determine partition names independently of storage architecture:
  TARGETP1=$(fdisk -l $TARGET |grep ^$TARGET |cut -d' ' -f1 |grep -E '[^0-9]1$')
  TARGETP2=$(fdisk -l $TARGET |grep ^$TARGET |cut -d' ' -f1 |grep -E '[^0-9]2$')
  TARGETP3=$(fdisk -l $TARGET |grep ^$TARGET |cut -d' ' -f1 |grep -E '[^0-9]3$')
fi # End [ $REFRESH -eq 0 ]

# Create temporary mount points for the ISO file and USB device:
mkdir -p /mnt
# ISO mount:
ISOMNT=$(mktemp -d -p /mnt -t alieniso.XXXXXX)
if [ ! -d $ISOMNT ]; then
  echo "*** Failed to create a temporary mount point for the ISO!"
  cleanup
  exit 1
else
  chmod 711 $ISOMNT
fi
# USB mounts:
USBMNT=$(mktemp -d -p /mnt -t alienusb.XXXXXX)
if [ ! -d $USBMNT ]; then
  echo "*** Failed to create a temporary mount point for the USB device!"
  cleanup
  exit 1
else
  chmod 711 $USBMNT
fi
US2MNT=$(mktemp -d -p /mnt -t alienus2.XXXXXX)
if [ ! -d $US2MNT ]; then
  echo "*** Failed to create a temporary mount point for the USB device!"
  cleanup
  exit 1
else
  chmod 711 $US2MNT
fi

# Mount the Linux partition:
mount -t auto ${TARGETP3} ${USBMNT}

# Loop-mount the ISO (or 1st partition if this is a hybrid ISO):
mount -o loop "${SLISO}" ${ISOMNT}

# Find out if the ISO contains an EFI bootloader and use it:
if [ ! -f ${ISOMNT}/EFI/BOOT/boot*.efi ]; then
  EFIBOOT=0
  echo "-- Note: UEFI boot file 'bootx64.efi' or 'bootia32.efi' not found on ISO."
  echo "-- UEFI boot will not be supported"
else
  EFIBOOT=1
fi

if [ $REFRESH -eq 0 ]; then
  # Collect data from the ISO initrd:
  IMGDIR=$(extract_initrd ${ISOMNT}/boot/initrd.img)
  read_initrddir ${IMGDIR} "DISTRO LIVEMAIN MARKER MEDIALABEL"
else
  # Collect data from the USB initrd:
  IMGDIR=$(extract_initrd ${USBMNT}/boot/initrd.img)
  read_initrddir ${IMGDIR} "DISTRO LIVEMAIN MARKER MEDIALABEL"
  # Collect customization parameters for the USB:
  read_distroconfig ${USBMNT}/${LIVEMAIN}/${DISTRO}_os.cfg
  # Display the old Live version:
  OLDVERSION="$(cat ${USBMNT}/.isoversion 2>/dev/null)"
  if [ -n "${OLDVERSION}" -a -n "${VERSION}" ]; then
    echo "--- Refreshing Live OS on USB (${OLDVERSION}) to '${VERSION}'."
  fi
  if [ -n "${USBPERSISTENCE}" ]; then
    # Persistence information was already updated in the past, so we use
    # the information on the USB instead of the value we found in the ISO:
    OLDPERSISTENCE="${USBPERSISTENCE}"
  fi
  if [ -n "${LUKSVOL}" ]; then
    # LUKS volume information was already updated in the past, so we use
    # the information on the USB instead of the value we found in the ISO:
    OLDLUKS="${LUKSVOL}"
  fi
fi

# Copy the ISO content into the USB Linux partition:
echo "--- Copying files from ISO to USB... takes some time."
if [ $VERBOSE -eq 1 ]; then
  # Show verbose progress:
  rsync -rlptD -v --progress --exclude=EFI ${ISOMNT}/* ${USBMNT}/
elif [ -z "$(rsync  --info=progress2 2>&1 |grep "unknown option")" ]; then
  # Use recent rsync to display some progress because this can take _long_ :
  rsync -rlptD --no-inc-recursive --info=progress2 --exclude=EFI \
    ${ISOMNT}/* ${USBMNT}/
else
  # Remain silent if we have an older rsync:
  rsync -rlptD --exclude=EFI ${ISOMNT}/* ${USBMNT}/
fi

if [ $REFRESH -eq 1 ]; then
  # Clean out old Live system data:
  echo "--- Cleaning out old Live system data."
  LIVEMAIN="$(echo $(find ${ISOMNT} -name "0099*" |tail -1) |rev |cut -d/ -f3 |rev)"
  rsync -rlptD --delete \
    ${ISOMNT}/${LIVEMAIN}/system/ ${USBMNT}/${LIVEMAIN}/system/
  if [ -f ${USBMNT}/boot/extlinux/ldlinux.sys ]; then
    chattr -i ${USBMNT}/boot/extlinux/ldlinux.sys 2>/dev/null 
  fi
  rsync -rlptD --delete \
    ${ISOMNT}/boot/ ${USBMNT}/boot/
fi

# Write down the version of the ISO image:
if [ -n "$VERSION" ]; then
  echo "$VERSION" > ${USBMNT}/.isoversion
fi

if [ -n "${HLUKSSIZE}" ]; then
  # If file extension is missing in the containername, add it now:
  if [ "${SLHOME%${CNTEXT}}" == "${SLHOME}" ]; then
    SLHOME="${SLHOME}${CNTEXT}"
  fi
  # If filename is a relative path, add a slash:
  if [ "${SLHOME:0:1}" != "/" ]; then 
    SLHOME="/${SLHOME}"
  fi
  # Create LUKS container file for /home aka DEFMNT;
  LUKSHOME="${SLHOME}"
  create_container ${TARGETP3} ${HLUKSSIZE} "${USBMNT}/${LUKSHOME}" luks ${DEFMNT}
fi

# Update the initrd configuration with regard to persistence and LUKS.
# If this is a refresh and anything changed to persistence, then the
# variable $PERSISTENCE will have the correct value when exing this function:
# If you want to move your LUKS home containerfile you'll have to do that
# manually - not a supported option for now.
update_distroconfig ${USBMNT}/${LIVEMAIN}/${DISTRO}_os.cfg

# Determine what we need to do with persistence if this is a refresh.
if [ $REFRESH -eq 1 ]; then
  if [ "${PERSISTENCE}" != "${OLDPERSISTENCE}" ]; then
    # The user specified a nonstandard persistence, so move the old one first;
    # hide any errors if it did not *yet* exist:
    mkdir -p ${USBMNT}/$(dirname ${PERSISTENCE})
    mv ${USBMNT}/${OLDPERSISTENCE}${CNTEXT} ${USBMNT}/${PERSISTENCE}${CNTEXT} 2>/dev/null
    mv ${USBMNT}/${OLDPERSISTENCE} ${USBMNT}/${PERSISTENCE} 2>/dev/null
  fi
  if [ -f ${USBMNT}/${PERSISTENCE}${CNTEXT} ]; then
    # If a persistence container exists, we re-use it:
    PERSISTTYPE="file"
    if cryptsetup isLuks ${USBMNT}/${PERSISTENCE}${CNTEXT} ; then
      # If the persistence file is LUKS encrypted we need to record its size:
      PLUKSSIZE=$(( $(du -sk $USBMNT/${PERSISTENCE}${CNTEXT} |tr '\t' ' ' |cut -f1 -d' ') / 1024 ))
    fi
  elif [ -d ${USBMNT}/${PERSISTENCE} -a "${PERSISTTYPE}" = "file" ]; then
    # A persistence directory exists but the user wants a container now;
    # so we will delete the persistence directory and create a container file
    # (sorry persistent data will not be migrated):
    rm -rf ${USBMNT}/${PERSISTENCE}
  fi
fi

# Now perform the actual steps:
if [ "${PERSISTTYPE}" = "dir" ]; then
  # Create persistence directory:
  mkdir -p ${USBMNT}/${PERSISTENCE}
elif [ "${PERSISTTYPE}" = "file" ]; then
  # Create container file for persistent storage.
  # If it is not going to be LUKS encrypted, we create a sparse file
  # that will at most eat up 90% of free space. Sparse means, the actual
  # block allocation will start small and grows as more changes are written.
  # Note: the word "persistence" below is a keyword for create_container:
  if [ -z "${PLUKSSIZE}" ]; then
    # Un-encrypted container:
    create_container ${TARGETP3} 90% ${USBMNT}/${PERSISTENCE} none persistence
  else
    # LUKS-encrypted container:
    create_container ${TARGETP3} ${PLUKSSIZE} ${USBMNT}/${PERSISTENCE} luks persistence
  fi
else
  echo "*** Unknown persistence type '${PERSISTTYPE}'!"
  cleanup
  exit 1 
fi

# Use extlinux to make the USB device bootable:
echo "--- Making the USB drive '$TARGET' bootable using extlinux..."
mv ${USBMNT}/boot/syslinux ${USBMNT}/boot/extlinux
mv ${USBMNT}/boot/extlinux/isolinux.cfg ${USBMNT}/boot/extlinux/extlinux.conf
rm -f ${USBMNT}/boot/extlinux/isolinux.*
if [ -f "$SYSLXLOC"/vesamenu.c32 ]; then
  # We will use our own copy only as a fallback,
  # because it is better to use the version that comes with syslinux:
  cp -a ${SYSLXLOC}/vesamenu.c32 ${USBMNT}/boot/extlinux/
fi
extlinux --install ${USBMNT}/boot/extlinux

if [ $EFIBOOT -eq 1 ]; then
  # Mount the EFI partition and copy /EFI as well as /boot directories into it:
  mount -t vfat -o shortname=mixed ${TARGETP2} ${US2MNT}
  mkdir -p ${US2MNT}/EFI/BOOT
  rsync -rlptD ${ISOMNT}/EFI/BOOT/* ${US2MNT}/EFI/BOOT/
  mkdir -p ${USBMNT}/boot
  echo "--- Copying EFI boot files from ISO to USB."
  if [ $VERBOSE -eq 1 ]; then
    rsync -rlptD -v ${ISOMNT}/boot/* ${US2MNT}/boot/
  else
    rsync -rlptD ${ISOMNT}/boot/* ${US2MNT}/boot/
  fi
  if [ $REFRESH -eq 1 ]; then
    # Clean out old Live system data:
    echo "--- Cleaning out old Live system data."
    rsync -rlptD --delete \
      ${ISOMNT}/EFI/BOOT/ ${US2MNT}/EFI/BOOT/
    rsync -rlptD --delete \
      ${ISOMNT}/boot/ ${US2MNT}/boot/
  fi
  # Copy the initrd over from the Linux partition:
  cat ${USBMNT}/boot/initrd.img > ${US2MNT}/boot/initrd.img
  sync
fi

# Write customization parameters to the USB:
write_distroconfig ${USBMNT}/${LIVEMAIN}/${DISTRO}_os.cfg

# No longer needed; umount the USB partitions so we can write a new MBR:
if mount |grep -qw ${USBMNT} ; then umount ${USBMNT} ; fi
if mount |grep -qw ${US2MNT} ; then umount ${US2MNT} ; fi

# Install a GPT compatible MBR record:
if [ -n "${GPTMBRBIN}" ]; then
  if [ -f ${GPTMBRBIN} ]; then
    cat ${GPTMBRBIN} > ${TARGET}
  fi
elif [ -f ${ISOMNT}/boot/syslinux/gptmbr.bin ]; then
  cat ${ISOMNT}/boot/syslinux/gptmbr.bin > ${TARGET}
else
  echo "*** Failed to make USB device bootable - 'gptmbr.bin' not found!"
  cleanup
  exit 1 
fi

# Unmount/remove stuff:
cleanup

# THE END

