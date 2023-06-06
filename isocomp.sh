#!/bin/bash
#
# Copyright 2022, 2023  Eric Hameleers, Eindhoven, NL
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
# This script can perform some specific changes on the USB stick
# containing an ISO of Slackware Live Edition,
# when you boot from that ISO using a multi-boot manager.
# - create a directory structure on the USB partition to add more
#   functionality to the ISO (e.g. load extra addons/optional modules).
# - create an encrypted container file for storing persistence data.
# - create an encrypted container file to mount on /home .
# - write all the above information into a configuration file for the ISO.
#
# -----------------------------------------------------------------------------

# Be careful:
set -e

# Limit the search path:
export PATH="/usr/sbin:/sbin:/usr/bin:/bin"

# Use of force is sometimes needed:
FORCE=0

# Version is obtained from the ISO metadata:
VERSION=""

# The extension for containerfiles accompanying an ISO is '.icc',
# whereas the persistent USB stick created with iso2usb.sh uses '.img'.
DEFEXT=".icc"
CNTEXT="${DEFEXT}"

# Default mount point for a LUKS container if not specified:
DEFMNT="/home"
LUKSMNT=""

# Values for container sizes:
PERSSIZE=""
LUKSSIZE=""
INCSIZE=""
LUKSVOL=""

# Associative array to capture LUKSVOL definitions:
declare -A CONTAINERS=()

# Values obtained from a pre-existing .cfg file:
ISOPERSISTENCE=""
LUKSCNT=""
LIVESLAKROOT=""

# Define ahead of time, so that cleanup knows about them:
IMGDIR=""
ISOMNT=""
CNTMNT=""
EXTENSION=""
PERSISTENCE=""

# Minimim free space (in MB) we want to have left in any partition
# after we are done.
# The default value can be changed from the environment:
MINFREE=${MINFREE:-10}

# Compressor used on the initrd ("gzip" or "xz --check=crc32");
# Note that the kernel's XZ decompressor does not understand CRC64:
COMPR="xz --check=crc32"

# These tools are required by the script, we will check for their existence:
REQTOOLS="cpio cryptsetup fsck gzip isoinfo lsblk resize2fs unsquashfs xz zstd"

#
#  -- function definitions --
#

# Clean up in case of failure:
cleanup() {
  # Clean up by unmounting our loopmounts, deleting tempfiles:
  echo "--- Cleaning up the staging area..."
  # During cleanup, do not abort due to non-zero exit code:
  set +e
  sync

  if [ -n "$CNTDEV" ]; then
    # In case of failure, only most recent LUKS mapped device is still open:
    if mount | grep -q ${CNTDEV} ; then
      umount -f ${CNTDEV}
      cryptsetup luksClose $(basename ${CNTFILE} ${CNTEXT})
      losetup -d ${LODEV}
    fi
  fi
  [ -n "${ISOMNT}" ] && ( umount -f ${ISOMNT} 2>/dev/null; rmdir $ISOMNT 2>/dev/null )
  [ -n "${CNTMNT}" ] && ( umount -f ${CNTMNT} 2>/dev/null; rmdir $CNTMNT 2>/dev/null )
  [ -n "${IMGDIR}" ] && ( rm -rf $IMGDIR )
  set -e
} # End of cleanup()

trap 'echo "*** $0 FAILED at line $LINENO ***"; cleanup; exit 1' ERR INT TERM

# Show the help text for this script:
showhelp() {
cat <<EOT
#
# Purpose: enhance the functionality when booting a Slackware Live ISO file.
# When supplying pathnames as parameter values below, use full pathnames in
# your local filesystem. The script will figure out where your USB disk
# partition is mounted and will adjust the path names accordingly
# in the USB configuration.
#
# $(basename $0) accepts the following parameters:
#   -d|--directory <path>         Create a liveslak directory structure to store
#                                 additional modules. The parameter value is
#                                 used as the root path below which the
#                                 liveslak/{addons,optional} subdirectories
#                                 will be created.
#   -e|--examples                 Show some common usage examples.
#   -f|--force                    Force execution in some cases where the script
#                                 reports an issue.
#   -h|--help                     This help text.
#   -i|--iso <fullpath>           Full path to your liveslak ISO image.
#   -l|--lukscontainer <fullpath> Full path to encrypted container file to be
#                                 created by this script, and to be mounted
#                                 in the live OS under /home
#                                 (or any other mountpoint you supply).
#                                 (filename needs to end in '${CNTEXT}'!).
#   -p|--persistence <fullpath  > Full path to encrypted persistence container
#                                 file to be created in the filesystem
#                                 (filename extension must be '${CNTEXT}'!).
#   -x|--extend <fullpath>        Full path to existing (encrypted) container
#                                 file that you want to extend in size
#                                 (filename needs to end in '${CNTEXT}'!).
#                                 Limitations:
#                                 - container needs to be LUKS encrypted, and
#                                 - internal filesystem needs to be ext{2,3,4}.
#   -L|--lcsize <size|perc>       Size of LUKS encrypted /home ; value is the
#                                 requested size of the container in kB, MB, GB,
#                                 or as a percentage of free space
#                                 (integer numbers only).
#                                 Examples: '-L 125M', '-L 2G', '-L 20%'.
#   -P|--perssize <size|perc>     Size of persistence container ; value is the
#                                 requested size of the container in kB, MB, GB,
#                                 or as a percentage of free space
#                                 (integer numbers only).
#                                 Examples: '-P 125M', '-P 2G', '-P 20%'.
#   -X|--extendsize <size|perc>   Extend size of existing container; value
#                                 is the requested extension of the container
#                                 in kB, MB, GB, or as percentage of free space
#                                 (integer numbers only).
#                                 Examples: '-X 125M', '-X 2G', '-X 20%'.
# 
EOT
} # End of showhelp()

# Show some common usage examples:
showexamples() {
cat <<EOT
#
# Some common usage examples for $(basename $0)
# ---------------------------------------------------------------------------
# First, mount your USB partition, for instance
# a Ventoy disk will be mounted for you at /run/media/<user>/Ventoy/.
# Then:
# ---------------------------------------------------------------------------
# Create a 1GB encrypted persistence container:
#   ./$(basename $0) -p /run/media/<user>/Ventoy/myfiles/persistence.icc -P 1G
#
# Create a 4GB encrypted home:
#   ./$(basename $0) -l /run/media/<user>/Ventoy/somedir/lukscontainers.icc -L 4000M -i /run/media/<user>/Ventoy/slackware64-live-current.iso
#
# Increase the size of that encrypted home container with another 2GB:
#   ./$(basename $0) -x /run/media/<user>/Ventoy/somedir/lukscontainers.icc -X 2G -i /run/media/<user>/Ventoy/slackware64-live-current.iso
#
# Create a 10GB encrypted container to be mounted on /data in the Live OS:
#   ./$(basename $0) -l /run/media/<user>/Ventoy/somedir/mydata.icc:/data -L 10G -i /run/media/<user>/Ventoy/slackware64-live-current.iso
#
# Create a liveslak directory structure for adding extra live modules:
#   ./$(basename $0) -d /run/media/<user>/Ventoy/myliveslak  -i /run/media/<user>/Ventoy/slackware64-live-current.iso
#
EOT
} # End of showexamples()

# Uncompress the initrd based on the compression algorithm used:
uncompressfs () {
  if $(file "${1}" | grep -qi ": gzip"); then
    gzip -cd "${1}"
  elif $(file "${1}" | grep -qi ": XZ"); then
    xz -cd "${1}"
  fi
} # End of uncompressfs()

# Read configuration data from the initrd inside the ISO:
read_initrd() {
  local IMGDIR="$1"
  cd ${IMGDIR}

  # Read the values of liveslak template variables in the init script:
  for TEMPLATEVAR in DISTRO LIVEMAIN MARKER MEDIALABEL ; do
    eval $(grep "^ *${TEMPLATEVAR}=" ./init |head -1)
  done
} # End read_initrd()

# Extract the initrd:
extract_initrd() {
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
get_part_mb_size() {
  local MYSIZE
  MYSIZE=$(df -P -BM ${1} |tail -n -1 |tr -s '\t' ' ' |cut -d' ' -f2)
  echo "${MYSIZE%M}"
} # End of get_part_mb_size()

# Determine free space of a mounted partition (in MB):
get_part_mb_free() {
  local MYSIZE
  MYSIZE=$(df -P -BM ${1} |tail -n -1 |tr -s '\t' ' ' |cut -d' ' -f4)
  echo "${MYSIZE%M}"
} # End of get_part_mb_free()

# Determine requested container size in MB (allow for '%|k|K|m|M|g|G' suffix):
cont_mb() {
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
expand_container() {
  local MYPART="$1" # disk partition
  local MYINC="$2"  # requested increase ('%|k|K|m|M|g|G' suffix)
  local MYFILE="$3" # full path to ${CNTEXT} containerfile
  local MYMAP=""    # Name of the device-mapped file

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

  # Append random bytes to the end of the container file:
  dd if=/dev/urandom of=${MYFILE} bs=1M count=${MYINC} oflag=append conv=notrunc 2>/dev/null

  # Unlock the LUKS encrypted container:
  MYMAP=$(basename ${MYFILE} ${CNTEXT})
  echo "--- Unlocking the LUKS container requires your passphrase..."
  until cryptsetup luksOpen ${MYFILE} ${MYMAP} ; do
    echo ">>> Did you type an incorrect passphrases?"
    read -p ">>> Press [ENTER] to try again or Ctrl-C to abort ..." REPLY 
  done

  # Run fsck so the filesystem is clean before we resize it:
  fsck -fvy /dev/mapper/${MYMAP}
  # Resize the filesystem to occupy the full new size:
  resize2fs /dev/mapper/${MYMAP}
  # Just to be safe:
  fsck -fvy /dev/mapper/${MYMAP}
} # End of expand_container()

# Create container file in the empty space of the partition
create_container() {
  CNTPART=$1 # partition containing the ISO
  CNTSIZE=$2 # size of the container file to create
  CNTFILE=$3 # ${CNTEXT} filename with full path
  CNTENCR=$4 # 'none' or 'luks'
  CNTUSED=$5 # 'persistence', '/home' or custom mountpoint

  # Create a container file or re-use previously created one:
  if [ -f ${CNTFILE} ]; then
    CNTSIZE=$(( $(du -sk ${CNTFILE} |tr '\t' ' ' |cut -f1 -d' ') / 1024 ))
    echo "--- Keeping existing '${CNTFILE}' (size ${CNTSIZE} MB)."
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
    echo "*** Check your commandline parameter."
    cleanup
    exit 1
  elif [ $CNTSIZE -ge $PARTFREE ]; then
    echo "*** Not enough free space for container file!"
    echo "*** Check your commandline parameter."
    cleanup
    exit 1
  fi

  echo "--- Creating ${CNTSIZE} MB container file using 'dd if=/dev/urandom', patience please..."
  mkdir -p $(dirname "${CNTFILE}")
  # Create a sparse file (not allocating any space yet):
  dd of=${CNTFILE} bs=1M count=0 seek=$CNTSIZE 2>/dev/null

  # Setup a loopback device that we can use with cryptsetup:
  LODEV=$(losetup -f)
  losetup $LODEV ${CNTFILE}
  if [ "${CNTENCR}" = "luks" ]; then
    # Format the loop device with LUKS:
    echo "--- Encrypting the container file with LUKS; takes SOME time..."
    echo "--- enter 'YES' and a passphrase:"
    until cryptsetup -y luksFormat $LODEV ; do
      echo ">>> Did you type two different passphrases?"
      read -p ">>> Press [ENTER] to try again or Ctrl-C to abort ..." REPLY 
    done
    # Unlock the LUKS encrypted container:
    echo "--- Unlocking the LUKS container requires your passphrase again..."
    until cryptsetup luksOpen $LODEV $(basename ${CNTFILE} ${CNTEXT}) ; do
      echo ">>> Did you type an incorrect passphrases?"
      read -p ">>> Press [ENTER] to try again or Ctrl-C to abort ..." REPLY 
    done
    CNTDEV=/dev/mapper/$(basename ${CNTFILE} ${CNTEXT})
    # Now we allocate blocks for the LUKS device. We write encrypted zeroes,
    # so that the file looks randomly filled from the outside.
    # Take care not to write more bytes than the internal size of the container:
    echo "--- Writing random data to encrypted container; takes LONG time..."
    CNTIS=$(( $(lsblk -b -n -o SIZE  $(readlink -f ${CNTDEV})) / 512))
    dd if=/dev/zero of=${CNTDEV} bs=512 count=${CNTIS} 2>/dev/null || true
  else
    CNTDEV=$LODEV
    # Un-encrypted container files remain sparse.
  fi

  # Format the now available block device with a linux fs:
  mkfs.ext4 ${CNTDEV}
  # Tune the ext4 filesystem:
  tune2fs -m 0 -c 0 -i 0 ${CNTDEV}

  if [ "${CNTUSED}" == "${DEFMNT}" ]; then
    # Copy the original /home content into the container.
    # NOTE: we only do this for /home, not for any other mountpoint!

    # Create a mount point for the unlocked container:
    CNTMNT=$(mktemp -d -p /var/tmp -t aliencnt.XXXXXX)
    if [ ! -d $CNTMNT ]; then
      echo "*** Failed to create temporary mount point for the LUKS container!"
      cleanup
      exit 1
    else
      chmod 711 $CNTMNT
    fi
    echo "--- Copying '${CNTUSED}' from ISO to container..."
    HOMESRC=$(find ${ISOMNT} -name "0099-slackware_zzzconf*" |tail -1)
    mount ${CNTDEV} ${CNTMNT}
    unsquashfs -n -d ${CNTMNT}/temp ${HOMESRC} ${CNTUSED}
    mv ${CNTMNT}/temp/${CNTUSED}/* ${CNTMNT}/
    rm -rf ${CNTMNT}/temp
    umount ${CNTDEV}
  fi

  # Don't forget to clean up after ourselves:
  if [ "${CNTENCR}" = "luks" ]; then
    cryptsetup luksClose $(basename ${CNTFILE} ${CNTEXT})
  fi
  losetup -d ${LODEV} || true

} # End of create_container()

read_config() {
  local MYISO="${1}"
  # Read ISO customization from the .cfg file if it exists:
    if [ -f "${MYISO%.iso}.cfg" ]; then
      for LIVEPARM in \
        BLACKLIST KEYMAP LIVE_HOSTNAME LIVESLAKROOT LOAD LOCALE LUKSVOL \
        NOLOAD ISOPERSISTENCE RUNLEVEL TWEAKS TZ XKB ;
      do
        # Read values from disk only if the variable has not been set yet:
        if [ -z "$(eval echo \$${LIVEPARM})" ]; then
          eval $(grep -w ^${LIVEPARM} ${MYISO%.iso}.cfg)
        fi
      done
    fi
} # End of read_config()

write_config() {
  local MYISO="${1}"
  # Write updated customization into the ISO .cfg:
  echo "# Liveslak ISO configuration file for ${VERSION}" > ${MYISO%.iso}.cfg 2>/dev/null
  echo "# Generated by $(basename $0) on $(date +%Y%m%d_%H%M)" >> ${MYISO%.iso}.cfg 2>/dev/null
  if [ $? -ne 0 ]; then
    echo "***  Media '${USBPART}' read-only, cannot write config file."
  else
    for LIVEPARM in \
      BLACKLIST KEYMAP LIVE_HOSTNAME LIVESLAKROOT LOAD LOCALE LUKSVOL \
      NOLOAD ISOPERSISTENCE RUNLEVEL TWEAKS TZ XKB ;
    do
      if [ -n "$(eval echo \$$LIVEPARM)" ]; then
        echo $LIVEPARM=$(eval echo \$$LIVEPARM) >> ${MYISO%.iso}.cfg
      fi 
    done
  fi
} # End of write_config()

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
    -d|--directory)
      LIVESLAKROOT="$2"
      [[ ${LIVESLAKROOT::1} != "/" ]] && LIVESLAKROOT="$(pwd)/${LIVESLAKROOT}"
      shift 2
      ;;
    -e|--examples)
      showexamples
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
    -i|--iso)
      SLISO="$(cd "$(dirname "$2")"; pwd)/$(basename "$2")"
      shift 2
      ;;
    -l|--lukscontainer)
      LUKSMNT="$(echo "$2" |cut -f2 -d:)"
      LUKSCNT="$(echo "$2" |cut -f1 -d:)"
      # If no mountpoint was specified, use the default mountpoint (/home):
      [ "$LUKSMNT" == "$LUKSCNT" ] && LUKSMNT=${DEFMNT}
      LUKSCNT="$(cd "$(dirname "$LUKSCNT")"; pwd)/$(basename "$LUKSCNT")"
      shift 2
      ;;
    -p|--persistence)
      PERSISTENCE="$(cd "$(dirname "$2")"; pwd)/$(basename "$2")"
      shift 2
      ;;
     -x|--extend)
      EXTENSION="$(cd "$(dirname "$2")"; pwd)/$(basename "$2")"
      shift 2
      ;;
    -L|--lcsize)
      LUKSSIZE="$2"
      shift 2
      ;;
    -P|--perssize)
      PERSSIZE="$2"
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

#
# Sanity checks:
#

if [ "$(id -u)" != "0" ]; then
  echo "*** You need to be root to run $(basename $0)."
  exit 1
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
  if [ $FORCE -eq 0 ]; then
    echo "--- Exiting."
    exit 1
  fi
fi

if [ -z "${SLISO}" ]; then
  echo "*** You must specify the path to the Live ISO (option '-i')!"
  exit 1
fi

if [ ! -f "$SLISO" ]; then
  echo "*** This is not a useable file: '$SLISO' !"
  exit 1
fi

if [ -z "${LIVESLAKROOT}${LUKSCNT}${PERSISTENCE}${EXTENSION}" ]; then
  echo "*** No action requested!"
  exit 1
fi

if [ -n "${PERSISTENCE}" ]; then
  if [ -z "${PERSSIZE}" ]; then
    echo "*** Persistence filename '${PERSISTENCE}' defined but no filesize provided!"
    echo "*** Not enabling persistence, please use '-P' parameter."
    exit 1
  elif [ "$(basename ${PERSISTENCE} ${CNTEXT})" == "$(basename ${PERSISTENCE})" ]; then
    echo  "*** File '${PERSISTENCE}' does not have an '${CNTEXT}' extension!"
    if [ $FORCE -eq 0 ]; then
      exit 1
    else
      CNTEXT=$(basename ${PERSISTENCE})
      if [ "${CNTEXT}" != "${CNTEXT##*.}" ]; then
        # File has a different extension:
        echo  "--- Accepting '${CNTEXT##*.}' extension for '${PERSISTENCE}'."
        CNTEXT=${CNTEXT##*.}
      else
        # File does not have an extension at all, so we add one:
        echo  "--- Adding '${DEFEXT}' extension to '${PERSISTENCE}'."
        PERSISTENCE="${PERSISTENCE}${DEFEXT}"
      fi
    fi
  fi
fi

if [ -n "${LUKSCNT}" ]; then
  if [ -z "${LUKSSIZE}" ]; then
    echo "*** LUKS container '${LUKSCNT}' defined but no filesize provided!"
    echo "*** Not adding encrypted ${LUKSMNT}, please use '-L' parameter."
    exit 1
  elif [ "$(basename ${LUKSCNT} ${CNTEXT})" == "$(basename ${LUKSCNT})" ]; then
    echo  "*** File '${LUKSCNT}' does not have an '${CNTEXT}' extension!"
    if [ $FORCE -eq 0 ]; then
      exit 1
    else
      CNTEXT=$(basename ${LUKSCNT})
      if [ "${CNTEXT}" != "${CNTEXT##*.}" ]; then
        # File has a different extension:
        echo  "--- Accepting '${CNTEXT##*.}' extension for '${LUKSCNT}'."
        CNTEXT=${CNTEXT##*.}
      else
        # File does not have an extension at all, so we add one:
        echo  "--- Adding '${DEFEXT}' extension to '${LUKSCNT}'."
        LUKSCNT="${LUKSCNT}${DEFEXT}"
      fi
    fi
  fi
fi

if [ -n "${EXTENSION}" ]; then
  if [ -z "${INCSIZE}" ]; then
    echo "*** LUKS container '${EXTENSION}' defined but no extansion size provided!"
    echo "*** Not extending encrypted ${EXTENSION}, please use '-X' parameter."
    exit 1
  elif [ "$(basename ${EXTENSION} ${CNTEXT})" == "$(basename ${EXTENSION})" ]; then
    echo  "*** File '${EXTENSION}' does not have an '${CNTEXT}' extension!"
    if [ $FORCE -eq 0 ]; then
      exit 1
    else
      CNTEXT=$(basename ${EXTENSION})
      if [ "${CNTEXT}" != "${CNTEXT##*.}" ]; then
        # File has a different extension:
        echo  "--- Accepting '${CNTEXT##*.}' extension for '${EXTENSION}'."
        CNTEXT=${CNTEXT##*.}
      else
        # File does not have an extension at all, so we add one:
        echo  "--- Adding '${DEFEXT}' extension to '${EXTENSION}'."
        EXTENSION="${EXTENSION}${DEFEXT}"
      fi
    fi
  fi
fi

# Determine name and mountpoint of the partition containing the ISO:
USBPART=$(cd $(dirname ${SLISO}) ; df . |tail -n -1 |tr -s ' ' |cut -d' ' -f1)
USBMNT=$(cd $(dirname ${SLISO}) ; df . |tail -n -1 |tr -s ' ' |cut -d' ' -f6)

# Determine size of the USB partition (in MB), and the free space:
USBPSIZE=$(get_part_mb_size ${USBMNT})
USBPFREE=$(get_part_mb_free ${USBMNT})

# Report the Slackware Live version:
VERSION=$(isoinfo -d -i "${SLISO}" 2>/dev/null |grep Application |cut -d: -f2-)
echo "--- The ISO on medium '${USBPART}' is '${VERSION}'"

# Try a write to the partition:
if touch ${USBMNT}/.rwtest 2>/dev/null && rm ${USBMNT}/.rwtest 2>/dev/null
then
  echo "--- The medium '${USBPART}' is writable."
else
  echo "--- Trying to remount readonly medium '${USBPART}' as writable..."
  mount -o remount,rw ${USBMNT}
  if [ $? -ne 0 ]; then
    echo "*** Failed to remount '${USBPART}' writable, unable to continue!"
    cleanup
    exit 1
  fi
fi

# Create a mount point for the ISO:
ISOMNT=$(mktemp -d -p /var/tmp -t alieniso.XXXXXX)
if [ ! -d $ISOMNT ]; then
  echo "*** Failed to create temporary mount point for the ISO!"
  cleanup
  exit 1
else
  chmod 711 $ISOMNT
  mount -o loop ${SLISO} ${ISOMNT}
fi

# Collect data from the USB initrd:
IMGDIR=$(extract_initrd ${ISOMNT}/boot/initrd.img)
read_initrd ${IMGDIR}

# Collect customization parameters for the ISO:
read_config ${SLISO}

# Determine where in LUKSVOL the /home is defined.
# The LUKSVOL value looks like:
# "/path/to/cntner1.icc:/mountpoint1,[/path/to/cntner2.icc:/mountpoint2,[...]]"
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

# Normalize paths on USB partition (remove mountpoint):
if [ -n "${PERSISTENCE}" ]; then
  PERSISTENCE="${PERSISTENCE#$USBMNT}"
fi
if [ -n "${LUKSCNT}" ]; then
  LUKSCNT="${LUKSCNT#$USBMNT}"
fi
if [ -n "${EXTENSION}" ]; then
  EXTENSION="${EXTENSION#$USBMNT}"
fi

# Should we create a liveslak root directory?
if [ -n "${LIVESLAKROOT}" ]; then
  # The directory may already exist, in which case we obtained its name
  # from the configfile. But creating directory tree is harmless:
  mkdir -p ${LIVESLAKROOT}/${LIVEMAIN}/{addons,optional,core2ram}
  # Normalize the path, removing the mount point:
  LIVESLAKROOT="$(cd "$(dirname "$LIVESLAKROOT")"; pwd)$(basename "$LIVESLAKROOT")"
  LIVESLAKROOT="${LIVESLAKROOT#$USBMNT}"
fi

# Should we create a persistence container?
if [ -n "${PERSISTENCE}" ]; then
  # Create LUKS persistence container file (or re-use it if existing):
  create_container ${USBPART} ${PERSSIZE} ${USBMNT}${PERSISTENCE} luks persistence
  ISOPERSISTENCE="${PERSISTENCE}"
fi

# Should we add a LUKS container to mount at /home or specified other mount?
if [ -n "${LUKSCNT}" ]; then
  if [ -v 'CONTAINERS["${LUKSMNT}"]' ] && [ "${LUKSCNT}" != "${CONTAINERS["${LUKSMNT}"]}" ]; then
    # The configfile specifies a different mount for container:
    echo "*** On-disk configuration defines an existing mountpoint ${LUKSMNT}"
    echo "*** at '${USBMNT}${CONTAINERS["${LUKSMNT}"]}',"
    echo "*** which is different from your '-l ${USBMNT}${LUKSCNT}'."
    if [ $FORCE -eq 0 ]; then
      echo "*** Not adding encrypted container for ${LUKSMNT} , please fix the entry"
      echo "*** in '${SLISO%.iso}.cfg',"
      echo "*** or supply the correct value for the '-l' parameter!"
      cleanup
      exit 1
    else
      echo "--- Accepting new mountpoint '${LUKSMNT}' for encrypted container ${LUKSMNT}"
    fi
  fi
  # Create LUKS container file for the mount point (or re-use it if existing):
  create_container ${USBPART} ${LUKSSIZE} ${USBMNT}${LUKSCNT} luks ${LUKSMNT}
  CONTAINERS["${LUKSMNT}"]="${LUKSCNT}"
fi

# Should we extend the size of a container?
if [ -n "${EXTENSION}" ]; then
  # Expand existing container file:
  expand_container ${USBPART} ${INCSIZE} ${USBMNT}/${EXTENSION}
fi

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

# Write customization parameters for the ISO to disk:
write_config ${SLISO}

# Write ISO version to the liveslak rootdir if that exists:
if [ -d "${USBMNT}/${LIVESLAKROOT}" ]; then
  echo "$VERSION" > ${USBMNT}/${LIVESLAKROOT}/.isoversion
fi

# Unmount/remove stuff:
cleanup

# THE END

