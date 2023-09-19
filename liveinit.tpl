#!/bin/sh
#
# Copyright 2004  Slackware Linux, Inc., Concord, CA, USA
# Copyright 2007, 2008, 2009, 2010, 2012  Patrick J. Volkerding, Sebeka, MN, USA
# Copyright 2015, 2016, 2017, 2018, 2019, 2020, 2021, 2022, 2023  Eric Hameleers, Eindhoven, NL
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
#
##################################################################################
# Changelog
# 10-Dec-2012 <mozes@slackware.com>
#  * Added support for the official Kernel parameters to select root filesystem
#    type ('rootfstype') and pause before attempting to mount the root filesystem
#    ('rootdelay').  The original parameters may continue to be used.
# 23-Oct-2015 <alien@slackware.com>
#  * Modified for booting as a Live filesystem.
##################################################################################

# The ISO creation script will create a filesystem with this label.
# Nevertheless, the user may have copied the ISO content to a different device.
MEDIALABEL="@MEDIALABEL@"

LIVEMAIN="@LIVEMAIN@"
MARKER="@MARKER@"

PERSISTENCE="@PERSISTENCE@"
PERSISTPART=""
PERSISTPATH="."

DISTRO="@DISTRO@"
CDISTRO="@CDISTRO@"
VERSION="@VERSION@"

CORE2RAMMODS="@CORE2RAMMODS@"
CORE2RAM=0

LIVEUID="@LIVEUID@"

LIVEMEDIA=""
LIVEPATH=""

DISTROCFG="@DISTRO@_os.cfg"
CFGACTION=""

# What extensions do we support for squashfs modules?
SQ_EXT_AVAIL="@SQ_EXT_AVAIL@"

# Defaults for keyboard, language and timezone:
DEF_KBD=@DEF_KBD@
DEF_LOCALE=@DEF_LOCALE@
DEF_TZ=@DEF_TZ@

# By default, let the media determine if we can write persistent changes:
# However, if we define TORAM=1, we will also set VIRGIN=1 when we want
# to avoid anything that writes to disk after we copy the OS to RAM;
# unless we explicitly use a persistence directory on the computer's local disk.
VIRGIN=0

# If set to '1', existing persistent data will be wiped:
WIPE_PERSISTENCE=0

# Used for debugging the init;
# Set DEBUG to '1' to enable explicit pauses showing blkid/mount info;
# '2' and higher enable verbose script execution;
# '3' pauses like '1' or '2' but won't show blkid/mount info;
# '4' dumps you into a debug shell right before the switch_root;
# '5' additionally saves the verbose init execution output to 'debug_init.log':
DEBUG=0
DEBUGV=" "

# Masochists can copy the live environment into RAM:
TORAM=0

# The default number of loop devices the Live OS will use (if you have
# a large number of addon modules, this value may be too low).
# Can be changed by the 'maxloops=' boot parameter:
MAXLOOPS=96

# By default we do not touch local hard disks (raid, lvm, btrfs):
LOCALHD=0

# Usability tweaks:
TWEAKS=""

# Deal with freetype's sub-pixel hinting.
# Enable the new v40 interpreter only if /etc/profile.d/freetype.sh is found.
# Otherwise (or in case 'tweaks=nsh' is passed at boot) disable the new
# interpreter and fall back to the old v35 interpreter.
SPH=1

# Perhaps we need to blacklist some kernel module(s):
BLACKLIST=""

# NFS root support:
HNMAC=""
HNMAC_ALLOWED="YES"
INTERFACE=""
NFSHOST=""

# Assume the default to be a readonly media - we write to RAM:
UPPERDIR=/mnt/live/changes
OVLWORK=/mnt/live/.ovlwork

# Persistence directory on writable media gets mounted below /mnt/media.
# If the user specifies a system partition instead,
# then the mount point will be a subdirectory of /mnt/live instead:
PPATHINTERNAL=/mnt/media

# Where will we mount the partition containing the ISO we are booting?
SUPERMNT=/mnt/super

# LUKS containers on writable media are found below /mnt/media,
# unless liveslak boots off an ISO image, in which case the container files
# are found below /mnt/super - the filesystem of the USB partition containing
# our ISO:
CPATHINTERNAL=/mnt/media

# If we boot directly off the ISO file, we want to know to enable extras.
# Possible values for ISOBOOT are 'diskpart','ventoy':
ISOBOOT=""
# The configuration file with customization for an ISO boot.
# Defaults to full pathname of the ISO, with extension 'cfg' instead of 'iso'.
ISOCFG=""

# The extension for containerfiles accompanying an ISO is '.icc',
# for a persistent USB stick the extension is '.img' and this is the default:
CNTEXT=".img"

# Password handling, assign random initialization:
DEFPW="7af0aed2-d900-4ed8-89f0"
ROOTPW=$DEFPW
LIVEPW=$DEFPW

# Max wait time for DHCP client to configure an interface:
DHCPWAIT=20

INITRD=$(cat /initrd-name)
WAIT=$(cat /wait-for-root)
KEYMAP=$(cat /keymap)
LUKSVOL=$(cat /luksdev)
INIT=/sbin/init

PATH="/sbin:/bin:/usr/sbin:/usr/bin"

# Mount /proc and /sys:
mount -n proc /proc -t proc
mount -n sysfs /sys -t sysfs
mount -n tmpfs /run -t tmpfs -o mode=0755,size=32M,nodev,nosuid,noexec

if grep devtmpfs /proc/filesystems 1>/dev/null 2>/dev/null ; then
  DEVTMPFS=1
  mount -n devtmpfs /dev -t devtmpfs -o size=8M
fi	

# Mount if this directory exists (so the kernel supports efivarfs):
if [ -d /sys/firmware/efi/efivars ]; then
  mount -o rw -t efivarfs none /sys/firmware/efi/efivars
fi

# Parse command line
for ARG in $(cat /proc/cmdline); do
  case $ARG in
    0|1|2|3|4|5|6|S|s|single)
      RUNLEVEL=$ARG
    ;;
    blacklist=*)
      BLACKLIST=$(echo $ARG | cut -f2 -d=)
    ;;
    debug)
      DEBUG=1
    ;;
    debug=*)
      DEBUG=$(echo $ARG | cut -f2 -d=)
      DEBUGV="-v"
    ;;
    dhcpwait=*)
      DHCPWAIT=$(echo $ARG | cut -f2 -d=)
    ;;
    domain=*)
      # generic syntax: sub.domain.some
      LIVE_DOMAIN=$(echo $ARG | cut -f2 -d=)
    ;;
    hostname=*)
      # generic syntax: hostname=newname[,qualifier]
      LIVE_HOSTNAME=$(echo $ARG | cut -f2 -d= | cut -f1 -d,)
      # Allow for the user to (mistakenly) add a domain component:
      if [ -n "$(echo "$LIVE_HOSTNAME". |cut -d. -f2-)" ]; then
        LIVE_DOMAIN=$(echo $LIVE_HOSTNAME |cut -d. -f2-)
        LIVE_HOSTNAME=$(echo $LIVE_HOSTNAME |cut -d. -f1)
      fi
      if [ "$(echo $ARG | cut -f2 -d= | cut -f2 -d,)" = "fixed" ]; then
        Keep hostname fixed i.e. never add a MAC address suffix:
        HNMAC_ALLOWED="NO"
      fi
    ;;
    init=*)
      INIT=$(echo $ARG | cut -f2 -d=)
    ;;
    kbd=*)
      KEYMAP=$(echo $ARG | cut -f2 -d=)
    ;;
    livemain=*)
      LIVEMAIN=$(echo $ARG | cut -f2 -d=)
    ;;
    livemedia=*)
      # generic syntax: livemedia=/dev/sdX
      # ISO syntax: livemedia=/dev/sdX:/path/to/slackwarelive.iso
      # Scan partitions for ISO: livemedia=scandev:/path/to/slackwarelive.iso
      LM=$(echo $ARG | cut -f2 -d=)
      LIVEMEDIA=$(echo $LM | cut -f1 -d:)
      LIVEPATH=$(echo $LM | cut -f2 -d:)
      unset LM
    ;;
    livepw=*)
      LIVEPW=$(echo $ARG | cut -f2 -d=)
    ;;
    load=*)
      LOAD=$(echo $ARG | cut -f2 -d=)
    ;;
    locale=*)
      LOCALE=$(echo $ARG | cut -f2 -d=)
    ;;
    localhd)
      LOCALHD=1
    ;;
    luksvol=*)
      # Format: luksvol=file1[:/mountpoint1][,file1[:/mountpoint2],...]
      LUKSVOL=$(echo $ARG | cut -f2 -d=)
    ;;
    maxloops=*)
      MAXLOOPS=$(echo $ARG | cut -f2 -d=)
    ;;
    nfsroot=*)
      # nfsroot=192.168.0.1:/path/to/liveslak
      NFSHOST=$(echo $ARG | cut -f2 -d= |cut -f1 -d:)
      NFSPATH=$(echo $ARG | cut -f2 -d= |cut -f2 -d:)
    ;;
    nic=*)
      # nic=<driver>:<interface>:<dhcp|static>[:ipaddr:netmask[:gateway]]
      ENET=$(echo $ARG | cut -f2 -d=)
    ;;
    cfg=*)
      CFGACTION=$(echo $ARG | cut -f2 -d=)
      if [ "${CFGACTION}" = "skip" ]; then DISTROCFG="" ; fi
    ;;
    noload=*)
      NOLOAD=$(echo $ARG | cut -f2 -d=)
    ;;
    nop)
      VIRGIN=1
    ;;
    nop=*)
      if [ "$(echo $ARG | cut -f2 -d=)" = "wipe" ]; then
        WIPE_PERSISTENCE=1
      fi
    ;;
    persistence=*)
      # Generic syntax: persistence=/path/to/persistencedir
      # Dir on harddisk partition: persistence=/dev/sdX:/path/to/persistencedir
      # Instead of device name, the value of its LABEL or UUID can be used too.
      PD=$(echo $ARG | cut -f2 -d=)
      PERSISTPART=$(echo $PD | cut -f1 -d:)
      PERSISTPATH=$(dirname $(echo $PD | cut -f2 -d:))
      PERSISTENCE=$(basename $(echo $PD | cut -f2 -d:))
      unset PD
      if [ "${PERSISTENCE})" = "changes" ]; then
        echo "${MARKER}:  Persistence directory cannot be called 'changes'."
        echo "${MARKER}:  Disabling persistence and recording changes in RAM."
        PERSISTPART=""
        PERSISTPATH="."
        PERSISTENCE="@PERSISTENCE@"
        VIRGIN=1
      fi
    ;;
    rescue)
      RESCUE=1
    ;;
    swap)
      USE_SWAP=1
    ;;
    rootpw=*)
      ROOTPW=$(echo $ARG | cut -f2 -d=)
    ;;
    toram)
      TORAM=1
      VIRGIN=1 # prevent writes to disk since we are supposed to run from RAM
    ;;
    toram=*)
      # Generic syntax: toram=type[,memperc]
      #   type: string value; os,core,all,none
      #   memperc: integer value, percentage RAM to reserve for liveslak
      # You can use this parameter to change the percentage RAM
      # used by liveslak, which is 50% for normal operation.
      # For instance when you have an insane amount of RAM, you can specify
      # a much lower percentage to be reserved for liveslak:
      #   toram=none,12
      TORAM=1
      TRTYPE="$(echo $ARG |cut -f2 -d= |cut -f1 -d,)"
      if [ "$TRTYPE" = "os" ]; then
        VIRGIN=0 # load OS modules into RAM, write persistent data to disk
      elif [ "$TRTYPE" = "core" ]; then
        CORE2RAM=1 # load Core OS modules into RAM
      elif [ "$TRTYPE" = "all" ]; then
        VIRGIN=1 # prevent writes to disk since we are supposed to run from RAM
      elif [ "$TRTYPE" = "none" ]; then
        TORAM=0 # we only want to change the percentage reserved memory
      fi
      RAMSIZE="$(echo $ARG |cut -f2 -d= |cut -f2 -d,)"
      if [ "$RAMSIZE" = "$TRTYPE" ]; then
        # memperc was not supplied on commandline:
        unset RAMSIZE
      fi
    ;;
    tweaks=*)
      # Comma-separated set of usability tweaks.
      # nga: no glamor 2d acceleration.
      # nsh: no sub-pixel hinting in freetype.
      # tpb: trackpoint scrolling while pressing middle mouse button.
      # syn: start synaptics daemon and extend X.Org capabilities.
      # ssh: start SSH daemon (disabled by default).
      TWEAKS=$(echo $ARG | cut -f2 -d=)
    ;;
    tz=*)
      TZ=$(echo $ARG | cut -f2 -d=)
    ;;
    waitforroot=*|rootdelay=*)
      WAIT=$(echo $ARG | cut -f2 -d=)
    ;;
    xkb=*)
      XKB=$(echo $ARG | cut -f2 -d=)
    ;;
  esac
done

# Verbose boot script execution:
if [ $DEBUG -ge 2 ]; then
  if [ $DEBUG -ge 5 ]; then
    # We save (verbose) shell output to local file;
    # These busybox compile options make it possible:
    # CONFIG_SH_IS_ASH=y
    # CONFIG_ASH_BASH_COMPAT=y
    exec 5> debug_init.log
    export BASH_XTRACEFD="5"
  fi
  set -x
fi

debugit () {
  if [ $DEBUG -eq 0 -o $DEBUG -gt 3 ]; then
    return
  elif [ $DEBUG -le 2 ]; then
    echo "DEBUG>> -- blkid info -- :"
    blkid | while read LINE ; do echo "DEBUG>> $LINE" ; done
    echo "DEBUG>> -- mount info -- :"
    mount | while read LINE ; do echo "DEBUG>> $LINE" ; done
  fi
  echo "DEBUG>> -- Press ENTER to continue -- : "
  read JUNK
  return
}

rescue() {
  echo
  if [ "x$1" != "x" ]; then
    echo "$1"
  else
    echo "RESCUE mode"
    echo
    echo "        You can try to fix or rescue your system now. If you want"
    echo "        to boot into your fixed system, mount your root filesystem"
    echo "        read-only under /mnt:"
    echo
    echo "            # mount -o ro -t filesystem root_device /mnt"
  fi
  echo
  echo "        Type 'exit' when things are done."
  echo
  /bin/sh
}

# If udevd is available, use it to generate block devices
# else use mdev to read sysfs and generate the needed devices 
if [ -x /sbin/udevd -a -x /sbin/udevadm ]; then
  /sbin/udevd --daemon --resolve-names=never
  /sbin/udevadm trigger --subsystem-match=block --action=add
  if [ -n "$NFSHOST" ]; then
    # We also need network devices if NFS root is requested:
    if [ -z "$(/sbin/udevadm trigger --subsystem-match=net --action=add -v -n |rev |cut -d/ -f1 |rev |grep -v lo)" ]; then
      /sbin/udevadm trigger --action=add $DEBUGV
    else
      /sbin/udevadm trigger --subsystem-match=net --action=add $DEBUGV
    fi
  fi
  /sbin/udevadm settle --timeout=10
else
  [ "$DEVTMPFS" != "1" ] && mdev -s
fi

# Load kernel modules (ideally this was already done by udev):
if [ ! -d /lib/modules/$(uname -r) ]; then
  echo "${MARKER}:  No kernel modules found for Linux $(uname -r)."
elif [ -x ./load_kernel_modules ]; then # use load_kernel_modules script:
  echo "${MARKER}:  Loading kernel modules from initrd image:"
  . ./load_kernel_modules 1>/dev/null 2>/dev/null
fi

# Sometimes the devices need extra time to be available.
# A root filesystem on USB is a good example of that.
echo "${MARKER}:  Sleeping $WAIT seconds to give slow USB devices some time."
sleep $WAIT
# Fire at least one blkid:
blkid 1>/dev/null 2>/dev/null

if [ "$RESCUE" = "" ]; then 
  if [ $LOCALHD -eq 1 ]; then
    # We will initialize RAID/LVM/BTRFS on local harddisks:
    # Initialize RAID:
    if [ -x /sbin/mdadm ]; then
      # If /etc/mdadm.conf is present, udev should DTRT on its own;
      # If not, we'll make one and go from there:
      if [ ! -r /etc/mdadm.conf ]; then
        /sbin/mdadm -E -s >/etc/mdadm.conf
        /sbin/mdadm -S -s
        /sbin/mdadm -A -s
        # This seems to make the kernel see partitions more reliably:
        fdisk -l /dev/md* 1> /dev/null 2> /dev/null
      fi
    fi

    # Initialize LVM:
    if [ -x /sbin/vgchange ]; then
      mkdir -p /var/lock/lvm      # this avoids useless warnings
      /sbin/vgchange -ay --ignorelockingfailure 2>/dev/null
      /sbin/udevadm settle --timeout=10
    fi

    # Scan for btrfs multi-device filesystems:
    if [ -x /sbin/btrfs ]; then
      /sbin/btrfs device scan
    fi
  fi

  # --------------------------------------------------------------------- #
  #                     SLACKWARE LIVE - START                            #
  # --------------------------------------------------------------------- #

  ## Support functions ##

  cidr_cvt() {
    # Function to convert the netmask from CIDR format to dot notation.
    # Number of args to shift, 255..255, first non-255 byte, zeroes
    set -- $(( 5 - ($1 / 8) )) 255 255 255 255 $(( (255 << (8 - ($1 % 8))) & 255 )) 0 0 0
    [ $1 -gt 1 ] && shift $1 || shift
    echo ${1-0}.${2-0}.${3-0}.${4-0}
  }

  get_dhcpcd_pid() {
    # Find the location of the PID file of dhcpcd:
    MYDEV="$1"
    if [ -s /run/dhcpcd/dhcpcd-${MYDEV}.pid ]; then
      echo "/run/dhcpcd/dhcpcd-${MYDEV}.pid"
    elif [ -s /run/dhcpcd/dhcpcd-${MYDEV}-4.pid ]; then
      echo "/run/dhcpcd/dhcpcd-${MYDEV}-4.pid"
    elif [ -s /run/dhcpcd-${MYDEV}.pid ]; then
      echo "/run/dhcpcd-${MYDEV}.pid"
    elif [ -s /run/dhcpcd-${MYDEV}-4.pid ]; then
      echo "/run/dhcpcd-${MYDEV}-4.pid"
    elif [ -s /run/${MYDEV}.pid ]; then
      echo "/run/${MYDEV}.pid"
    else
      echo UNKNOWNLOC
    fi
  }

  setnet() {
    # Find and configure the network interface for NFS root support.
    # Assume nothing about the method of network configuration:
    ENET_MODE="ask"

    echo "${MARKER}:  Configuring network interface for NFS mount."

    # Does the commandline have NIC information for us?
    # Format is 'nic=driver:interface:<dhcp|static>:ip:mask:gw'
    if [ -n "$ENET" ]; then
      DRIVER=$(echo $ENET |cut -f1 -d:)
      INTERFACE=$(echo $ENET |cut -f2 -d:)
      ENET_MODE=$(echo $ENET |cut -f3 -d:)
      if [ "$ENET_MODE" = "static" ]; then
        IPADDR=$(echo $ENET |cut -f4 -d:)
        NETMASK=$(echo $ENET |cut -f5 -d:)
        # We allow for CIDR notation of the netmask (0 < NETMASK < 25):
        if [ "$(echo $NETMASK |tr -cd '\.')" != "..." ]; then
          NETMASK=$(cidr_cvt $NETMASK)
        fi
        # Determine BROADCAST:
        eval $(ipcalc -b $IPADDR $NETMASK)
        # Not mandatory:
        GATEWAY=$(echo $ENET | cut -f6 -d:)
      fi
    fi

    # If no interface is present the cmdline should have provided a driver:
    if [ $(cat /proc/net/dev |grep ':' |sed -e "s/^ *//" |cut -f1 -d: |grep -v lo |wc -l) -eq 0 ]; then
      if [ "x${DRIVER}" != "x" ]; then
        # This takes silent care of 'DRIVER=auto' as well...
        modprobe ${DRIVER} 1>/dev/null 2>/dev/null
      fi
    fi

    # Let's determine the interface:
    if [ "x$INTERFACE" = "x" -o "$INTERFACE" = "auto" ]; then
      # Cmdline did not provide a nic or it's "auto" to let dhcpcd find out:
      for EDEV in $(cat /proc/net/dev |grep ':' |sed -e "s/^ *//" |cut -f1 -d: |grep -v lo) ; do
        if grep -q $(echo ${EDEV}: |cut -f 1 -d :): /proc/net/wireless ; then
          continue # skip wireless interfaces
        fi
        # If this configures an interface, we're done with dhcpcd afterwards:
        /sbin/dhcpcd -L -p -j /var/log/dhcpcd.log -t $DHCPWAIT $EDEV &
      done
      unset EDEV
      # Wait at most DHCPWAIT seconds for a DHCP-configured interface to appear:
      for ITER in $(seq 0 $DHCPWAIT); do
        if $(ip -f inet -o addr show | grep -v " lo " 1>/dev/null 2>/dev/null)
        then
          # Found one!
          break
        fi
        sleep 1
      done
      # What interface did dhcpcd configure?
      INTERFACE=""
      for EDEV in $(cat /proc/net/dev |grep ':' |sed -e "s/^ *//" |cut -f1 -d: |grep -v lo); do
        if [ -s $(get_dhcpcd_pid $EDEV) ]; then
          INTERFACE="${EDEV}"
          break
        fi
      done
      unset EDEV
    fi

    if [ "x$INTERFACE" = "x" ]; then
      # Failed to find a configured interface... desperate measure:
      echo "${MARKER}:  Failed to find network interface... assuming 'eth0'. Trouble ahead."
      INTERFACE="eth0"
    fi

    # We know our INTERFACE, so let's configure it:
    if [ "$ENET_MODE" = "ask" -o "$ENET_MODE" = "dhcp" ]; then
      # Invoke dhcpcd only if it was not called yet:
      if [ ! -s $(get_dhcpcd_pid $INTERFACE) ]; then
        /sbin/dhcpcd -L -p -j /var/log/dhcpcd.log -t $DHCPWAIT $INTERFACE
      fi
    else
      # Kill dhcpcd if we used it to find a statically configured interface:
      if [ -s $(get_dhcpcd_pid $INTERFACE) ]; then
        /sbin/dhcpcd -k $INTERFACE
      fi
      # Static IP address requires IPADDRESS, NETMASK, NETMASK at a minimum:
      ifconfig $INTERFACE $IPADDR netmask $NETMASK broadcast $BROADCAST
      if [ -n "$GATEWAY" ]; then
        route add default gw $GATEWAY metric 1
      fi
    fi

    # Store the interface MAC address so we may modify the hostname with it:
    HNMAC=$(ip link show ${INTERFACE} |grep link/ether |tr -s ' ' |cut -d ' ' -f3 |tr -d ':')

  } # End setnet()

  find_loop() {
    # The losetup of busybox is different from the real losetup - watch out!
    lodev=$(losetup -f 2>/dev/null)
    if [ -z "$lodev" ]; then
      # We exhausted the available loop devices, so create the block device:
      for NOD in $(seq 0 ${MAXLOOPS}); do
        if [ ! -b /dev/loop${NOD} ]; then
          mknod -m660 /dev/loop${NOD} b 7 ${NOD}
          break
        fi
      done
      lodev=/dev/loop${NOD}
    elif [ ! -b $lodev ]; then
      # We exhausted the available loop devices, so create the block device:
      mknod -m660 $lodev b 7 $(echo $lodev |sed 's%/dev/loop%%')
    fi
    echo "$lodev"
  }

  mod_base() {
    MY_MOD="$1"

    echo $(basename ${MY_MOD}) |rev |cut -d. -f2- |rev
  }

  find_mod() {
    MY_LOC="$1"
    MY_SUBSYS=$(basename "$1")
    MY_SYSROOT=$(dirname "$1")
    MY_COREMODS="$(echo boot ${CORE2RAMMODS} zzzconf |tr ' ' '|')"

    # For all except core2ram, this is a simple find & sort, but for core2ram
    # we have to search two locations (system and core2ram) and filter the
    # results to return only the Core OS modules:
    if [ "${MY_SUBSYS}" = "core2ram" ]; then
      ( for MY_EXT in ${SQ_EXT_AVAIL} ; do
          echo "$(find ${MY_SYSROOT}/core2ram/ ${MY_SYSROOT}/system/ -name "*.${MY_EXT}" 2>/dev/null |grep -Ew ${DISTRO}_"(${MY_COREMODS})")"
        done
      ) | sort
    else
      ( for MY_EXT in ${SQ_EXT_AVAIL} ; do
          echo "$(find ${MY_LOC} -name "*.${MY_EXT}" 2>/dev/null)"
        done
      ) | sort
    fi
  }

  find_modloc() {
    MY_LOC="$1"
    MY_BASE="$2"

    if [ $TORAM -ne 0 ]; then
      # If we need to copy the module to RAM, we need a place for that:
      mkdir -p /mnt/live/toram
      # Copy the module to RAM before mounting it, preserving relative path:
      MODNAME="$(basename ${MY_LOC})"
      MODRELPATH="$(dirname ${MY_LOC} |sed "s,$MY_BASE,,")"
      mkdir -p /mnt/live/toram/${MODRELPATH}
      cp "${MY_LOC}" "/mnt/live/toram/${MODRELPATH}"
      MY_LOC="/mnt/live/toram/${MODRELPATH}/${MODNAME}"
    fi

    echo "${MY_LOC}"
  }

  load_modules() {
    # SUBSYS can be 'system', 'addons', 'optional', 'core2ram':
    SUBSYS="$1"

    # Find all supported modules:
    SUBSYSSET="$(find_mod /mnt/media/${LIVEMAIN}/${SUBSYS}/) $(find_mod ${SUPERMNT}/${LIVESLAKROOT}/${LIVEMAIN}/${SUBSYS}/)"
    if [ "$SUBSYS" = "optional" ]; then
      # We need to load any core2ram modules first:
      SUBSYSSET="$(find_mod /mnt/media/${LIVEMAIN}/core2ram/) $(find_mod ${SUPERMNT}/${LIVESLAKROOT}/${LIVEMAIN}/core2ram/ ${SUBSYSSET})"
    fi
    for MODULE in ${SUBSYSSET} ; do
      # Strip path and extension from the modulename:
      MODBASE="$(mod_base ${MODULE})"
      if [ "$SUBSYS" = "optional" ]; then
        # Load one or more optionals by using boot parameter 'load':
        # load=mod1[,mod2[,mod3]]
        if [ -z "$LOAD" -o -z "$(echo ",${LOAD}," |grep -i ",$(echo $MODBASE |cut -d- -f2),")" ]; then
          continue
        fi
      elif [ "$SUBSYS" = "addons" ]; then
        # Skip loading one or more addons by using boot parameter 'noload':
        # noload=mod1[,mod2[,mod3]]
        if [ -n "$NOLOAD" -a -n "$(echo ",${NOLOAD}," |grep -i ",$(echo $MODBASE |cut -d- -f2),")" ]; then
          echo "$MODBASE" >> /mnt/live/modules/skipped
          continue
        fi
      fi
      MODLOC=$(find_modloc ${MODULE} /mnt/media)
      if [ -d /mnt/live/modules/${MODBASE} ]; then
        echo "${MARKER}:  duplicate $SUBSYS module '${MODBASE}', excluding it from the overlay."
        echo "$MODBASE" >> /mnt/live/modules/dupes
      else
        mkdir /mnt/live/modules/${MODBASE}
        mount -t squashfs -o loop ${MODLOC} /mnt/live/modules/${MODBASE}
        if [ $? -eq 0 ]; then
          if echo ${MODBASE} | grep -q ^0000 -a ; then
            echo "${MARKER}:  ${CDISTRO} Live based on liveslak-${VERSION} #$(cat /mnt/live/modules/${MODBASE}/${MARKER})"
          fi
          RODIRS=":/mnt/live/modules/${MODBASE}${RODIRS}"
          # 0099-* are the Live customizations, exclude those for setup2hd:
          if ! echo ${MODBASE} | grep -q ^0099 ; then
            FS2HD=":/mnt/live/modules/${MODBASE}${FS2HD}"
          fi
        else
          echo "${MARKER}:  Failed to mount $SUBSYS module '${MODBASE}', excluding it from the overlay."
            echo "$MODBASE" >> /mnt/live/modules/failed
            rmdir /mnt/live/modules/${MODBASE} 2>/dev/null
        fi
      fi
    done

    # Warn if Core OS modules were requested but none were found/mounted;
    if [ "$SUBSYS" = "core2ram" ]; then
      MY_COREMODS="$(echo ${CORE2RAMMODS} |tr ' ' '|')"
      if [ -z "$(ls -1 /mnt/live/modules/ |grep -Ew ${DISTRO}_"(${MY_COREMODS})")" ] ; then
        echo "${MARKER}:  '$SUBSYS' modules were not found. Trouble ahead..."
      fi
    fi
  }

  # Function input is a series of device node names. Return all block devices:
  ret_blockdev () {
    local OUTPUT=""
    for IDEV in $* ; do
      if [ -e /sys/block/$(basename $IDEV) ]; then
        # We found a matching block device:
        OUTPUT="$OUTPUT$IDEV "
      fi
    done
    # Trim trailing space:
    echo $OUTPUT |cat
  }

  # Function input is a series of device node names.  Return all partitions:
  ret_partition () {
    local OUTPUT=""
    for IDEV in $* ; do
      if [ -e /sys/class/block/$(basename $IDEV)/partition ]; then
        # We found a matching partition:
        OUTPUT="$OUTPUT$IDEV "
      fi
    done
    # Trim trailing space:
    echo $OUTPUT |cat
  }

  # Return device node of Ventoy partition if found:
  # Function input:
  # (param 1) Ventoy OS parameter block (512 bytes file).
  # (param 2) action
  # 'isopath' request: return full path to the ISO on the USB filesystem;
  # 'devpartition' request:
  #    return the device node for the partition containing the ISO file;
  # 'diskuuid' request: return the UUID for the disk;
  # 'partnr' request: return the number of the partition containing the ISO;
  ret_ventoy () {
    local VOSPARMS="$1"
    local VACTION="$2"
    local DISKSIZE=""
    local BDEV=""
    local IPART=""
    local VENTPART=""

    if [ "$VACTION" == "isopath" ]; then
      echo $(hexdump -s 45 -n 384 -e '384/1 "%01c""\n"' $VOSPARMS)
    elif [ "$VACTION" == "diskuuid" ]; then
      echo $(hexdump -s 481 -n 4 -e '4/1 "%02x "' ${VOSPARMS} \
        | awk '{ for (i=NF; i>1; i--) printf("%s",$i); print $i; }' )
    elif [ "$VACTION" == "partnr" ]; then
      echo $(( 0x$(hexdump -s 41 -n 2 -e '2/1 "%02x "' ${VOSPARMS} \
        | awk '{ for (i=NF; i>1; i--) printf("%s",$i); print $i; }' )
      ))
    elif [ "$VACTION" == "devpartition" ]; then
      PARTNR=$(( 0x$(hexdump -s 41 -n 2 -e '2/1 "%02x "' ${VOSPARMS} \
        | awk '{ for (i=NF; i>1; i--) printf("%s",$i); print $i; }' )
      ))
      DISKSIZE=$(( 0x$(hexdump -s 33 -n 8 -e '8/1 "%02x "' ${VOSPARMS} \
        | awk '{ for (i=NF; i>1; i--) printf("%s",$i); print $i; }' )
      ))
      # Determine which block device (only one!) reports this disk size (bytes):
      for BDEV in $(find /sys/block/* |grep -Ev '(ram|loop)') ; do
        BDEV=$(basename $BDEV) 
        # The 'size' value is sectors, not bytes!
        # Logical block size in Linux is commonly 512 bytes:
        BDEVSIZE=$(( $(cat /sys/block/${BDEV}/size) * $(cat /sys/block/${BDEV}/queue/logical_block_size) ))
        if [ $BDEVSIZE -eq $DISKSIZE ]; then
          # Found a block device with matching size in bytes:
          for IPART in $(ret_partition $(blkid |cut -d: -f1) | grep -v loop) ;
          do
            if [ -e /sys/block/$BDEV/$(basename $IPART)/partition ]; then
              if [ $(cat /sys/block/$BDEV/$(basename $IPART)/partition) -eq $PARTNR ]; then
                # Found the correct partition number on matching disk:
                VENTPART="$IPART $VENTPART"
              fi
            fi
          done
        fi
      done
      if [ $(echo $VENTPART |wc -w) -eq 1 ]; then
        # We found the Ventoy ISO-containing partition.
        # Trim leading/trailing spaces:
        echo $VENTPART |xargs
      else
        # Zero or multiple matching block devices found, fall back to 'scandev':
        echo scandev
      fi
    fi
  }

  ## End support functions ##

  # We need a mounted filesystem here to be able to do a switch_root later,
  # so we create one in RAM:
  if [ $TORAM -eq 1 ]; then
    RAMSIZE="${RAMSIZE:-90}%"  # 90% by default to load the entire OS in RAM
  else
    RAMSIZE="${RAMSIZE:-50}%"  # 50% is the default value.
  fi
  mount -t tmpfs -o defaults,size=${RAMSIZE} none /mnt

  # Find the Slackware Live media.
  # TIP: Increase WAIT to give USB devices a chance to be seen by the kernel.
  mkdir /mnt/media

  # Multi ISO boot managers first.

  # --- Ventoy ---
  # If we boot an ISO via Ventoy, this creates a device-mapped file
  # '/dev/mapper/ventoy' which liveslak could use to mount that ISO,
  # but specifying '-t iso9660' will fail to mount it.
  # Omitting the '-t iso9660' makes the mount succceed.
  # liveslak is 'Ventoy compatible':
  # Ventoy will not execute its hooks and leaves all the detection to us.
  # It will create the device-mapped file /dev/mapper/ventoy still.
  VENTID="VentoyOsParam-77772020-2e77-6576-6e74-6f792e6e6574"
  VENTVAR="/sys/firmware/efi/vars/${VENTID}"
  if [ ! -d "${VENTVAR}" ]; then
    # Newer Slackware will use 'efivars' rather than 'vars' directory;
    VENTVAR="/sys/firmware/efi/efivars/${VENTID}"
  fi
  if [ -d "${VENTVAR}" ]; then
    echo "${MARKER}:  (UEFI) Ventoy ISO boot detected..."
    ISOBOOT="ventoy"
    VENTOSPARM="${VENTVAR}/data"
  elif [ -f "${VENTVAR}" ]; then
    # Kernel >= 6.x does not offer a clean data sctructure, so we need to
    # find the offset of the data block in the efivars file:
    cat "${VENTVAR}" > /vent.dmp
  else
    # Detect Ventoy in memory (don't use the provided hooks), see
    # https://www.ventoy.net/en/doc_compatible_format.html:
    dd if=/dev/mem of=/vent.dmp bs=1 skip=$((0x80000)) count=$((0xA0000-0x80000)) 2>/dev/null
  fi
  if [ -f /vent.dmp ]; then
    # Use 'strings' to find the decimal offset of the magic string;
    # With 'xargs' we remove leading and ending spaces:
    if strings -t d /vent.dmp 1>/dev/null 2>/dev/null ; then
      # Busybox in Slackware 15.0 or newer:
      OFFSET=$(strings -t d /vent.dmp |grep '  www.ventoy.net' |xargs |cut -d' ' -f1)
    else
      # Busybox in Slackware 14.2 or older:
      OFFSET=$(strings -o /vent.dmp |grep '  www.ventoy.net' |xargs |cut -d' ' -f1)
    fi
    if [ -n "${OFFSET}" ]; then
      echo "${MARKER}:  (BIOS) Ventoy ISO boot detected..."
      ISOBOOT="ventoy"
      # Save the 512-byte Ventoy OS Parameter block:
      dd if=/vent.dmp of=/vent_os_parms bs=1 count=512 skip=$OFFSET 2>/dev/null
      VENTOSPARM="/vent_os_parms"
    fi
  fi
  if [ "$ISOBOOT" == "ventoy" ]; then
    LIVEPATH=$(ret_ventoy $VENTOSPARM isopath)
    if [ -e /dev/mapper/ventoy ]; then
      LIVEMEDIA=$(dmsetup table /dev/mapper/ventoy |tr -s ' ' |cut -d' ' -f 4)
      LIVEMEDIA=$(readlink -f /dev/block/${LIVEMEDIA})
      # Having the ISO device-mapped to /dev/dm-0 prevents liveslak from
      # mounting the underlying partition, so we delete the mapped device:
      dmsetup remove /dev/mapper/ventoy
    else
      # Return Ventoy device partition (or 'scandev'):
      LIVEMEDIA=$(ret_ventoy $VENTOSPARM devpartition)
    fi
  fi

  if [ -n "$NFSHOST" ]; then
    # NFS root.  First configure our network interface:
    setnet

    # Allow for debugging the PXE boot:
    debugit

    # Mount the NFS share and hope for the best:
    mount -t nfs -o nolock,vers=3 $NFSHOST:$NFSPATH /mnt/media
    LIVEALL="$NFSHOST:$NFSPATH"
    LIVEMEDIA="$LIVEALL"
    # No writing on NFS exports, overlayfs does not support it:
    VIRGIN=1
  elif [ -z "$LIVEMEDIA" ]; then
    # LIVEMEDIA not specified on the boot commandline using "livemedia="
    # Start digging:
    # Filter out the block devices, only look at partitions at first:
    # The blkid function in busybox behaves differently than the regular blkid!
    # It will return all devices with filesystems and list LABEL UUID and TYPE.
    LIVEALL=$(blkid |grep LABEL="\"$MEDIALABEL\"" |cut -d: -f1)
    # We pick the first hit that is not a block device, which will give
    # precedence to a USB stick over a CDROM ISO for instance:
    LIVEMEDIA=$(ret_partition $LIVEALL |cut -d' ' -f1)
    if [ ! -z "$LIVEMEDIA" ]; then
      # That was easy... we found the media straight away.
      # Determine filesystem type ('iso9660' means we found a CDROM/DVD)
      LIVEFS=$(blkid $LIVEMEDIA |rev |cut -d'"' -f2 |rev)
      mount -t $LIVEFS -o ro $LIVEMEDIA /mnt/media
    else
      LIVEMEDIA=$(ret_blockdev $LIVEALL |cut -d' ' -f1)
      if [ ! -z "$LIVEMEDIA" ]; then
        # We found a block device with the correct label (non-UEFI media).
        # Determine filesystem type ('iso9660' means we found a CDROM/DVD)
        LIVEFS=$(blkid $LIVEMEDIA |rev |cut -d'"' -f2 |rev)
        [ "$LIVEFS" = "swap" ] && continue
        mount -t $LIVEFS -o ro $LIVEMEDIA /mnt/media
      else
        # Bummer.. label not found; the ISO was extracted to a different device.
        # Separate partitions from block devices, look at partitions first:
        for SLDEVICE in $(ret_partition $(blkid |cut -d: -f1)) $(ret_blockdev $(blkid |cut -d: -f1)) ; do
          # We rely on the fact that busybox blkid puts TYPE"..." at the end:
          SLFS=$(blkid $SLDEVICE |rev |cut -d'"' -f2 |rev)
          [ "$SLFS" = "swap" ] && continue
          mount -t $SLFS -o ro $SLDEVICE /mnt/media
          if [ -f /mnt/media/${LIVEMAIN}/system/0099-${DISTRO}_zzzconf-*.s* ];
          then
            # Found our media!
            LIVEALL=$SLDEVICE
            LIVEMEDIA=$SLDEVICE
            LIVEFS=$(blkid $LIVEMEDIA |rev |cut -d'"' -f2 |rev)
            break
          else
            umount $SLDEVICE
            unset SLDEVICE
          fi
        done
      fi
    fi
    if [ -n "$LIVEMEDIA" ]; then
      # Gotcha!
      break
    fi
    sleep 1
  else
    # LIVEMEDIA was specified on the boot commandline using "livemedia=",
    # or ISO was booted by a compatible multi ISO bootmanager:
    if [ "$LIVEMEDIA" != "scandev" -a ! -b "$LIVEMEDIA" ]; then
      # Passed a UUID or LABEL?
      LIVEALL=$(findfs UUID=$LIVEMEDIA 2>/dev/null) || LIVEALL=$(findfs LABEL=$LIVEMEDIA 2>/dev/null)
      LIVEMEDIA="$LIVEALL"
    else
      LIVEALL="$LIVEMEDIA"
    fi
    if [ -z "$LIVEALL" ]; then
      echo "${MARKER}:  Live media '$LIVEMEDIA' not found... trouble ahead."
    else
      if [ -n "$LIVEPATH" -a "$LIVEPATH" != "$LIVEMEDIA" ]; then
        # Boot option used: "livemedia=/dev/sdX:/path/to/live.iso",
        # or: "livemedia=scandev:/path/to/live.iso",
        # instead of just: "livemedia=/dev/sdX".
        #
        # First mount the partition and then loopmount the ISO:
        mkdir -p ${SUPERMNT}
        #
        if [ "$LIVEMEDIA" = "scandev" ]; then
          # Scan partitions to find the one with the ISO and set LIVEMEDIA:
          echo "${MARKER}:  Scanning for '$LIVEPATH'..."
          for ISOPART in $(ret_partition $(blkid |cut -d: -f1)) $(ret_blockdev $(blkid |cut -d: -f1)) ; do
            PARTFS=$(blkid $ISOPART |rev |cut -d'"' -f2 |rev)
            # Abuse the $SUPERMNT a bit, we will actually use it later:
            mount -t $PARTFS -o ro $ISOPART ${SUPERMNT}
            if [ -f ${SUPERMNT}/${LIVEPATH} ]; then
              # Found our ISO!
              LIVEMEDIA=$ISOPART
              umount $ISOPART
              unset ISOPART
              break
            else
              umount $ISOPART
            fi
          done
          if [ -n "$ISOPART" ]; then
            echo "${MARKER}:  Partition scan unable to find ISO, trouble ahead."
          fi
        fi
        # At this point we know $LIVEMEDIA - either because the bootparameter
        # specified it or else because the 'scandev' found it for us.
        # Next we will re-define LIVEMEDIA to point to the actual ISO file
        # on the mounted live media:
        SUPERFS=$(blkid $LIVEMEDIA |rev |cut -d'"' -f2 |rev)
        SUPERPART=$LIVEMEDIA
        mount -t ${SUPERFS} -o ro ${SUPERPART} ${SUPERMNT}
        if [ -f "${SUPERMNT}/${LIVEPATH}" ]; then
          LIVEFS=$(blkid "${SUPERMNT}/${LIVEPATH}" |rev |cut -d'"' -f2 |rev)
          LIVEALL="${SUPERMNT}/${LIVEPATH}"
          LIVEMEDIA="$LIVEALL"
          MOUNTOPTS="loop"
          if [ -z "$ISOBOOT" ]; then
            ISOBOOT="diskpart"
          fi
        fi
      fi
      LIVEFS=$(blkid $LIVEMEDIA |rev |cut -d'"' -f2 |rev)
      mount -t $LIVEFS -o ${MOUNTOPTS:-ro} $LIVEMEDIA /mnt/media
    fi
  fi

  if [ -n "${ISOBOOT}" ]; then
    # Containerfiles used in conjunction with ISO files have '.icc' extension,
    # aka 'ISO Container Companion' ;-)
    CNTEXT=".icc"
    # Search for containers in another place than the default /mnt/media:
    CPATHINTERNAL=${SUPERMNT}
  fi

  # ---------------------------------------------------------------------- #
  #                                                                        #
  # Finished determining the media availability, it should be mounted now. #
  #                                                                        # 
  # ---------------------------------------------------------------------- #

  if [ ! -z "$LIVEMEDIA" ]; then
    echo "${MARKER}:  Live media found at ${LIVEMEDIA}."
    if [ ! -f /mnt/media/${LIVEMAIN}/system/0099-${DISTRO}_zzzconf-*.s* ]; then
      echo "${MARKER}:  However, live media was not mounted... trouble ahead."
    fi
    if [ "$LIVEMEDIA" != "$LIVEALL" ]; then
      echo "${MARKER}:  NOTE: Multiple partitions with '$MEDIALABEL' label were found ($(echo $LIVEALL))... success not guaranteed."
    fi
  else
    echo "${MARKER}:  No live media found... trouble ahead."
    echo "${MARKER}:  Try adding \"rootdelay=20\" to the boot command."
    debugit
    rescue
  fi

  debugit

  # liveslak can optionally load a OS config file "@DISTRO@_os.cfg"
  # which contains "VARIABLE=value" lines, where VARIABLE is one of
  # the following variables that are used below in the live init script:
  #   BLACKLIST, KEYMAP, LIVE_HOSTNAME, LOAD, LOCALE, LUKSVOL,
  #   NOLOAD, RUNLEVEL, TWEAKS, TZ, XKB. 
  if [ -z "$CFGACTION" ]; then
    # Read OS configuration from disk file if present and set any variable
    # from that file if it has not yet been defined in the init script
    # (prevent this by adding 'cfg=skip' to the boot commandline).
    if [ -f "/mnt/media/${LIVEMAIN}/${DISTROCFG}" ]; then
      echo "${MARKER}:  Reading config from /${LIVEMAIN}/${DISTROCFG}"
      for LIVEPARM in \
        BLACKLIST KEYMAP LIVE_HOSTNAME LOAD LOCALE LUKSVOL \
        NOLOAD RUNLEVEL TWEAKS TZ XKB ;
      do
        if [ -z "$(eval echo \$${LIVEPARM})" ]; then
          eval $(grep -w ^${LIVEPARM} /mnt/media/${LIVEMAIN}/${DISTROCFG})
        fi
      done
    fi
  elif [ "$CFGACTION" = "write" ]; then
    # Write liveslak OS parameters to disk:
    echo > /mnt/media/${LIVEMAIN}/${DISTROCFG} 2>/dev/null
    if [ $? -ne 0 ]; then
      echo "${MARKER}:  Live media read-only, cannot write config file."
    else
      echo "${MARKER}:  Writing config to /${LIVEMAIN}/${DISTROCFG}"
      for LIVEPARM in \
        BLACKLIST KEYMAP LIVE_HOSTNAME LOAD LOCALE LUKSVOL \
        NOLOAD RUNLEVEL TWEAKS TZ XKB ;
      do
        if [ -n "$(eval echo \$$LIVEPARM)" ]; then
          echo $LIVEPARM=$(eval echo \$$LIVEPARM) >> /mnt/media/${LIVEMAIN}/${DISTROCFG}
        fi 
      done
    fi
  fi

  # When booted from an ISO, liveslak optionally reads parameters
  # from a file with the same full filename as the ISO,
  # but with '.cfg' extension instead of '.iso':
  if [ -n "$ISOBOOT" ] && [ -z "$CFGACTION" ]; then
    # The partition's filesystem containing the ISO is mounted at ${SUPERMNT}:
    ISOCFG="${SUPERMNT}/$(dirname ${LIVEPATH})/$(basename ${LIVEPATH} .iso).cfg"
    if [ -f "$ISOCFG" ]; then
      # Read ISO live customization from disk file if present,
      # and set any variable from that file:
      echo "${MARKER}:  Reading ISO boot config from ${ISOCFG#$SUPERMNT})"
      for LISOPARM in \
        BLACKLIST KEYMAP LIVE_HOSTNAME LIVESLAKROOT LOAD LOCALE LUKSVOL \
        NOLOAD ISOPERSISTENCE RUNLEVEL TWEAKS TZ XKB ;
      do
        eval $(grep -w ^${LISOPARM} ${ISOCFG})
      done
      # Handle any customization.
      if [ -n "${ISOPERSISTENCE}" ]; then
        # Persistence container located on the USB stick - strip the extension:
        PERSISTENCE=$(basename ${ISOPERSISTENCE%.*})
        PERSISTPATH=$(dirname ${ISOPERSISTENCE})
        PERSISTPART=${SUPERPART}
      fi
    fi
  fi

  # Some variables require a value before continuing, so if they were not set
  # on the boot commandline nor in a config file, we take care of it now:
  if [ -z "$KEYMAP" ]; then
    KEYMAP="${DEF_KBD}"
  fi
  if [ -z "$TZ" ]; then
    TZ="${DEF_TZ}"
  fi
  if [ -z "$LOCALE" ]; then
    LOCALE="${DEF_LOCALE}"
  fi

  # Load a custom keyboard mapping:
  if [ -n "$KEYMAP" ]; then
    echo "${MARKER}:  Loading '$KEYMAP' keyboard mapping."
    tar xzOf /etc/keymaps.tar.gz ${KEYMAP}.bmap | loadkmap
  fi

  # Start assembling our live system components below /mnt/live :
  mkdir /mnt/live

  # Mount our squashed modules (.sxz or other supported extension)
  mkdir /mnt/live/modules

  if [ $TORAM -ne 0 ]; then
    echo "${MARKER}:  Copying Live modules to RAM, please be patient."
  fi

  # Modules were created in specific order and will be mounted in that order.
  # In the lowerdirs parameter for the overlay, the module with the highest
  # number (i.e. created last) will be leftmost in a colon-separated list:
  RODIRS=""
  FS2HD=""

  if [ $CORE2RAM -eq 1 ]; then
    # Only load the Core OS modules:
    echo "${MARKER}:  Loading Core OS into RAM."
    load_modules core2ram
  else
    # First, the base Slackware system components:
    load_modules system

    # Next, the add-on (3rd party etc) components, if any:
    # Remember, module name must adhere to convention: "NNNN-modname-*.sxz"
    # where 'N' is a digit and 'modname' must not contain a dash '-'.
    load_modules addons

    # And finally any explicitly requested optionals (like nvidia drivers):
    ## TODO:
    ## Automatically load the nvidia driver if we find a supported GPU:
    # NVPCIID=$(lspci -nn|grep NVIDIA|grep VGA|rev|cut -d'[' -f1|rev|cut -d']' -f1|tr -d ':'|tr [a-z] [A-Z])
    # if cat /mnt/media/${LIVEMAIN}/optional/nvidia-*xx.ids |grep -wq $NVPCIID ;
    # then
    #   LOAD="nvidia,${LOAD}"
    # fi
    ## END TODO:
    # Remember, module name must adhere to convention: "NNNN-modname-*.sxz"
    # where 'N' is a digit and 'modname' must not contain a dash '-'.
    load_modules optional
  fi

  # Get rid of the starting colon:
  RODIRS=$(echo $RODIRS |cut -c2-)
  FS2HD=$(echo $FS2HD |cut -c2-)

  if [ $TORAM -ne 0 ]; then
    echo "${MARKER}:  Live OS has been copied to RAM."
    # Inform user in case we won't do persistent writes and the medium
    # does not contain LUKS-encrypted containers to mount:
    if [ $VIRGIN -ne 0 -a -z "$LUKSVOL" ]; then
      echo "${MARKER}:  You can now safely remove the live medium."
    fi
    if [ "LIVEFS" = "iso9660" ]; then
      eject ${LIVEMEDIA}
    fi
  fi

  # --------------------------------------------------------------- #
  #                                                                 #
  # Setup persistence in case our media is writable, *and* the user #
  # has created a persistence directory or container on the media,  #
  # otherwise we let the block changes accumulate in RAM only.      #
  #                                                                 #
  # --------------------------------------------------------------- #

  # Was a partition specified containing a persistence directory,
  # and is it different from the live medium?
  if [ -n "${PERSISTPART}" ]; then
    # If partition was specified as UUID/LABEL, or as 'scandev',
    # we need to figure out the partition device ourselves:
    if [ "${PERSISTPART}" != "scandev" -a ! -b "${PERSISTPART}" ]; then
      TEMPP=$(findfs UUID=${PERSISTPART} 2>/dev/null) || TEMPP=$(findfs LABEL=${PERSISTPART} 2>/dev/null)
      if [ -n "${TEMPP}" ]; then
        PERSISTPART=${TEMPP}
      else
        echo "${MARKER}:  Partition '${PERSISTPART}' needed for persistence was not found."
        echo "${MARKER}:  Falling back to recording changes in RAM."
        PERSISTPART=""
        VIRGIN=1
      fi
      unset TEMPP
    elif [ "${PERSISTPART}" = "scandev" ]; then
      # Scan partitions to find the one with the persistence directory:
      echo "${MARKER}:  Scanning for partition with '${PERSISTENCE}'..."
      ppartdir=".persistence_$(od -An -N1 -tu1 /dev/urandom|tr -d ' ')"
      mkdir -p /mnt/live/${ppartdir}
      for PPART in $(ret_partition $(blkid |cut -d: -f1)) ; do
        PPARTFS=$(blkid $PPART |rev |cut -d'"' -f2 |rev)
        # Mount the partition and peek inside for a directory or container:
        mount -t $PPARTFS -o ro ${PPART} /mnt/live/${ppartdir}
        if [ -d /mnt/live/${ppartdir}/${PERSISTPATH}/${PERSISTENCE} ] || [ -f /mnt/live/${ppartdir}/${PERSISTPATH}/${PERSISTENCE}${CNTEXT} ]; then
          # Found our persistence directory/container!
          PERSISTPART=$PPART
          unset PPART
          umount /mnt/live/${ppartdir}
          break
        else
          umount /mnt/live/${ppartdir}
        fi
      done
      rmdir /mnt/live/${ppartdir}
      if [ -n "$PPART" ]; then
        echo "${MARKER}:  Partition scan unable to find persistence."
        echo "${MARKER}:  Falling back to recording changes in RAM."
        PERSISTPART=""
        VIRGIN=1
      fi
    fi
  fi

  debugit

  # ------------------------------------------------------------------ #
  #                                                                    #
  # At this point, we either have determined the persistence partition #
  # via UUID/LABEL/scandev, or else we failed to find one,             #
  # and then VIRGIN has been set to '1' and PERSISTPART to "".         #
  #                                                                    #
  # ------------------------------------------------------------------ #

  if [ -n "${PERSISTPART}" ]; then
    # Canonicalize the input and the media devices,
    # to ensure that we are talking about two different devices:
    MPDEV=$(df /mnt/media |tail -1 |tr -s ' ' |cut -d' ' -f1)
    REALMP=$(readlink -f ${MPDEV})
    REALPP=$(readlink -f ${PERSISTPART})
    if [ "${REALMP}" != "${REALPP}" ]; then
      # The liveslak media is different from the persistence partition.
      # Mount the partition readonly to access the persistence directory:
      ppdir=".persistence_$(od -An -N1 -tu1 /dev/urandom|tr -d ' ')"
      mkdir -p /mnt/live/${ppdir}
      mount -o ro ${PERSISTPART} /mnt/live/${ppdir}
      if [ $? -ne 0 ]; then
        echo "${MARKER}:  Failed to mount persistence partition '${PERSISTPART}' readonly."
        echo "${MARKER}:  Falling back to recording changes in RAM."
        rmdir /mnt/live/${ppdir}
        VIRGIN=1
      else
        # Explicitly configured persistence has priority over regular
        # persistence settings, and also overrides the boot parameter 'nop':
        if [ -n "${ISOBOOT}" ]; then
          # Boot from ISO, persistence is on the filesystem containing the ISO:
          PPATHINTERNAL=${SUPERMNT}
        else
          # We use the above created directory:
          PPATHINTERNAL=/mnt/live/${ppdir}
        fi
        VIRGIN=0
      fi
    fi
  fi

  debugit

  # At this point, if we use persistence then its partition is either
  # the live media (mounted on /mnt/media), a system partition
  # (mounted on /mnt/live/${ppdir}) or the partition containing the ISO if we
  # booted off that.
  # The variable ${PPATHINTERNAL} points to its mount point,
  # and the partition is mounted read-only.

  # Create the mount point for the writable upper directory of the overlay.
  # First, we deal with the case of persistence (VIRGIN=0) and then we
  # deal with a pure Live system without persistence (VIRGIN=1):

  if [ $VIRGIN -eq 0 ]; then
    if [ -d ${PPATHINTERNAL}/${PERSISTPATH}/${PERSISTENCE} ] || [ -f ${PPATHINTERNAL}/${PERSISTPATH}/${PERSISTENCE}${CNTEXT} ]; then
      # Remount the partition r/w - we need to write to the persistence area.
      # The value of PPATHINTERNAL will be different for USB stick or harddisk:
      mount -o remount,rw ${PPATHINTERNAL}
      if [ $? -ne 0 ]; then
        echo "${MARKER}:  Failed to mount persistence partition '${PERSISTPART}' read/write."
        echo "${MARKER}:  Falling back to recording changes in RAM."
        VIRGIN=1
      fi
    fi
  fi

  # We have now checked whether the persistence area is actually writable.

  if [ $VIRGIN -eq 0 ]; then
    # Persistence directory (either on writable USB or else on system harddisk):
    if [ -d ${PPATHINTERNAL}/${PERSISTPATH}/${PERSISTENCE} ]; then
      # Try a write... just to be dead sure:
      if touch ${PPATHINTERNAL}/${PERSISTPATH}/${PERSISTENCE}/.rwtest 2>/dev/null && rm ${PPATHINTERNAL}/${PERSISTPATH}/${PERSISTENCE}/.rwtest 2>/dev/null ; then
        # Writable media and we are allowed to write to it.
        if [ "$WIPE_PERSISTENCE" = "1" -o -f ${PPATHINTERNAL}/${PERSISTPATH}/${PERSISTENCE}/.wipe ]; then
          echo "${MARKER}:  Wiping existing persistent data in '${PERSISTPATH}/${PERSISTENCE}'."
          rm -f ${PPATHINTERNAL}/${PERSISTPATH}/${PERSISTENCE}/.wipe 2>/dev/null
          find ${PPATHINTERNAL}/${PERSISTPATH}/${PERSISTENCE}/ -mindepth 1 -exec rm -rf {} \; 2>/dev/null
        fi
        echo "${MARKER}:  Writing persistent changes to media directory '${PERSISTENCE}'."
        UPPERDIR=${PPATHINTERNAL}/${PERSISTPATH}/${PERSISTENCE}
        OVLWORK=${PPATHINTERNAL}/${PERSISTPATH}/.ovlwork
      else
        echo "${MARKER}:  Failed to write to persistence directory '${PERSISTENSE}'."
        echo "${MARKER}:  Falling back to recording changes in RAM."
        VIRGIN=1
      fi
    # Use a container file instead of a directory for persistence:
    elif [ -f ${PPATHINTERNAL}/${PERSISTPATH}/${PERSISTENCE}${CNTEXT} ]; then
      # Find a free loop device to mount the persistence container file:
      prdev=$(find_loop)
      prdir=persistence_$(od -An -N1 -tu1 /dev/urandom |tr -d ' ')
      mkdir -p /mnt/live/${prdir}
      losetup $prdev ${PPATHINTERNAL}/${PERSISTPATH}/${PERSISTENCE}${CNTEXT}
      # Check if the persistence container is LUKS encrypted:
      if cryptsetup isLuks $prdev 1>/dev/null 2>/dev/null ; then
        echo "${MARKER}:  Unlocking LUKS encrypted persistence file '${PERSISTPATH}/${PERSISTENCE}${CNTEXT}'"
        cryptsetup luksOpen $prdev ${PERSISTENCE} </dev/tty0 >/dev/tty0 2>&1
        if [ $? -ne 0 ]; then
          echo "${MARKER}:  Failed to unlock persistence file '${PERSISTPATH}/${PERSISTENCE}${CNTEXT}'."
          echo "${MARKER}:  Falling back to RAM."
        else
          # LUKS properly unlocked; from now on use the mapper device instead:
          prdev=/dev/mapper/${PERSISTENCE}
        fi
      fi
      prfs=$(blkid $prdev 2>/dev/null |rev |cut -d'"' -f2 |rev)
      mount -t $prfs $prdev /mnt/live/${prdir} 2>/dev/null
      if [ $? -ne 0 ]; then
        echo "${MARKER}:  Failed to mount persistence file '${PERSISTPATH}/${PERSISTENCE}${CNTEXT}'."
        echo "${MARKER}:  Falling back to RAM."
      else
        if [ "$WIPE_PERSISTENCE" = "1" -o -f /mnt/live/${prdir}/${PERSISTENCE}/.wipe ]; then
          echo "${MARKER}:  Wiping existing persistent data in '${PERSISTPATH}/${PERSISTENCE}${CNTEXT}'."
          rm -f /mnt/live/${prdir}/${PERSISTENCE}/.wipe 2>/dev/null
          find /mnt/live/${prdir}/${PERSISTENCE}/ -mindepth 1 -exec rm -rf {} \; 2>/dev/null
        fi
        echo "${MARKER}:  Writing persistent changes to file '${PERSISTPATH}/${PERSISTENCE}${CNTEXT}'."
        UPPERDIR=/mnt/live/${prdir}/${PERSISTENCE}
        OVLWORK=/mnt/live/${prdir}/.ovlwork
      fi
    fi
  else
    echo "${MARKER}:  Writing changes to RAM - no persistence:"
    if [ ! -z "$LUKSVOL" ]; then
      # Even without persistence, we need to be able to write to the partition
      # if we are using a LUKS container file:
      if [ -n "$ISOBOOT" ]; then
        mount -o remount,rw ${SUPERMNT}
      else
        mount -o remount,rw /mnt/media
      fi
    else
      mount -o remount,ro /mnt/media
    fi
  fi

  debugit

  # Create the writable upper directory, plus the workdir which is required
  # for overlay to function (the two must be in the same POSIX filesystem):
  [ ! -d ${UPPERDIR} ] && mkdir -p ${UPPERDIR}
  [ ! -d ${OVLWORK} ] && mkdir -p ${OVLWORK}

  # Create the overlays of readonly and writable directories:
  mkdir -p /mnt/${LIVEMAIN}fs
  mkdir -p /mnt/overlay
  # We are going to use a readonly overlay of the unmodified filesystem
  # as source for 'setup2hd':
  mount -t overlay -o lowerdir=${FS2HD} overlay /mnt/${LIVEMAIN}fs
  # And this is the actual Live overlay:
  mount -t overlay -o workdir=${OVLWORK},upperdir=${UPPERDIR},lowerdir=${RODIRS} overlay /mnt/overlay
  MNTSTAT=$?
  if [ $VIRGIN -eq 0 ]; then
    if [ $MNTSTAT -ne 0 ]; then
      # Failed to create the persistent overlay - try without persistence:
      echo "${MARKER}:  Failed to create persistent overlay, attempting to continue in RAM."
      # Clean up and re-create upper and work directories:
      rmdir $UPPERDIR 2>/dev/null
      rmdir $OVLWORK 2>/dev/null
      [ -n "${prdir}" ] && rmdir /mnt/live/${prdir} 2>/dev/null
      VIRGIN=1
      UPPERDIR=/mnt/live/changes
      OVLWORK=/mnt/live/.ovlwork
      mkdir -p ${UPPERDIR}
      mkdir -p ${OVLWORK}
      mount -t overlay -o workdir=${OVLWORK},upperdir=${UPPERDIR},lowerdir=${RODIRS} overlay /mnt/overlay
    else
      # Use a predictable name "changes" for the changes-directory which we can
      # use later to squash its contents into a new .sxz module if needed.
      # Will be a directory when there's no persistence, otherwise a bind-mount.
      mkdir -p /mnt/live/changes
      mount --rbind ${UPPERDIR} /mnt/live/changes
    fi
  fi

  debugit

  # Mount a tmpfs on /run in the overlay so that we can store volatile files.
  # On boot, rc.S will recognize and accept the mount:
  mount -t tmpfs tmpfs /mnt/overlay/run -o mode=0755,size=32M,nodev,nosuid,noexec

  # Make the underpinning RAM fs accessible in the live system (for fun):
  mkdir -p /mnt/overlay/mnt/live
  mount --rbind /mnt/live /mnt/overlay/mnt/live
  mkdir -p /mnt/overlay/mnt/${LIVEMAIN}fs
  mount --bind /mnt/${LIVEMAIN}fs /mnt/overlay/mnt/${LIVEMAIN}fs

  # Same for the Linux filesystem on the USB stick:
  mkdir -p /mnt/overlay/mnt/livemedia
  if [ $TORAM -eq 0 ]; then
    mount --bind /mnt/media /mnt/overlay/mnt/livemedia
  else
    # For PXE server we need to provide kernel and initrd too,
    # not just the modules:
    cp -af /mnt/media/boot /mnt/live/toram/
    mount --bind /mnt/live/toram /mnt/overlay/mnt/livemedia
  fi

  if [ -n "$ISOBOOT" ]; then
    # Expose the filesystem on the USB stick when we booted off an ISO there:
    mkdir -p /mnt/overlay/mnt/supermedia
    mount --bind ${SUPERMNT} /mnt/overlay/mnt/supermedia
  fi

  if [ ! -z "$USE_SWAP" ]; then
    # Use any available swap device:
    for SWAPD in $(blkid |grep TYPE="\"swap\"" |cut -d: -f1) ; do
      echo "${MARKER}:  Enabling swapping to '$SWAPD'"
      echo "$SWAPD  swap  swap defaults  0  0" >> /mnt/overlay/etc/fstab
    done
  fi

  if [ ! -z "$LUKSVOL" ]; then
    # Bind any LUKS container into the Live filesystem:
    for luksvol in $(echo $LUKSVOL |tr ',' ' '); do
      luksfil="$(echo $luksvol |cut -d: -f1)"
      luksmnt="$(echo $luksvol |cut -d: -f2)"
      luksnam="$(echo $(basename $luksfil) |tr '.' '_')"
      if [ "$luksmnt" = "$luksfil" ]; then
        # No optional mount point specified, so we use the default: /home/
        luksmnt="/home"
      fi

      # Find a free loop device:
      lodev=$(find_loop)

      losetup $lodev ${CPATHINTERNAL}/$luksfil
      echo "Unlocking LUKS encrypted container '$luksfil' at mount point '$luksmnt'"
      cryptsetup luksOpen $lodev $luksnam </dev/tty0 >/dev/tty0 2>&1
      if [ $? -ne 0 ]; then
        echo "${MARKER}:  Failed to unlock LUKS container '$luksfil'... trouble ahead."
      else
        # Create the mount directory if it does not exist (unlikely):
        mkdir -p /mnt/overlay/$luksmnt

        # Let Slackware mount the unlocked container:
        luksfs=$(blkid /dev/mapper/$luksnam |rev |cut -d'"' -f2 |rev)
        if ! grep -q "^/dev/mapper/$luksnam" /mnt/overlay/etc/fstab ; then
          echo "/dev/mapper/$luksnam  $luksmnt  $luksfs  defaults  1  1" >> /mnt/overlay/etc/fstab
        fi
        # On shutdown, ensure that the container gets locked again:
        if ! grep -q "$luksnam $luksmnt" /mnt/overlay/etc/crypttab ; then
          echo "$luksnam $luksmnt" >> /mnt/overlay/etc/crypttab
        fi
      fi
    done
  fi

  debugit

  if [ ! -z "$KEYMAP" ]; then
    # Configure custom keyboard mapping in console and X:
    echo "${MARKER}:  Switching live console to '$KEYMAP' keyboard"
    cat <<EOT > /mnt/overlay/etc/rc.d/rc.keymap
#!/bin/sh
# Load the keyboard map.  More maps are in /usr/share/kbd/keymaps.
if [ -x /usr/bin/loadkeys ]; then
 /usr/bin/loadkeys ${KEYMAP}
fi
EOT
    chmod 755 /mnt/overlay/etc/rc.d/rc.keymap
    echo "KEYMAP=${KEYMAP}" > /mnt/overlay/etc/vconsole.conf
  fi
  if [ ! -z "$KEYMAP" -o ! -z "$XKB" ]; then
    # Set a keyboard mapping in X.Org, derived from the console map if needed:
    # Variable XKB can be set to "XkbLayout,XkbVariant,XkbOptions".
    # For example "xkb=ch,fr,compose:sclk,grp:alt_shift_toggle"
    # Note that the XkbOptions can be several comma-separated values.
    # The XkbLayout and XkbVariant values must not contain commas.
    # You can set just the XkbVariant by adding something like "kbd=ch xkb=,fr"

    # Catch a missing comma in the "$XKB" string value which messes with 'cut':
    XKB="$XKB,"
    XKBLAYOUT=$(echo $XKB |cut -d, -f1)
    XKBVARIANT=$(echo $XKB |cut -d, -f2)
    XKBOPTIONS=$(echo $XKB |cut -d, -f3-)
    # Ensure that XKBLAYOUT gets a value;
    # XKBVARIANT and XKBOPTIONS are allowed to be empty.
    if [ -z "$XKBLAYOUT" ]; then
      if [ -z "$KEYMAP" ]; then
        XKBLAYOUT="us"
      else
        XKBLAYOUT="$(echo $KEYMAP |cut -c1-2)"
      fi
    fi
  else
    XKBLAYOUT="us"
  fi
  echo "${MARKER}:  Switching live X desktop to '$XKBLAYOUT' keyboard"

  if [ "$XKBLAYOUT" != "us" ]; then
    # If the layout is not 'us' then add 'us' as a secondary nevertheless:
    XKBLAYOUT="$XKBLAYOUT,us"
    XKBVARIANT="$XKBVARIANT,"
  fi

  if [ -z "$XKBOPTIONS" ]; then
    # If the user did not specify any X keyboard options then we will
    # determine a set of sane defaults:
    if [ "$XKBLAYOUT" != "us" ]; then
      # User should be able to switch between layouts (Alt-Shift toggles).
      # Also, many languages use the AltGr key, so we will use Shift-AltGr
      # (press them, then release them, then enter your two keys of choice)
      # as the Compose Key - see "/usr/share/X11/xkb/rules/xorg.lst":
      XKBOPTIONS="grp:alt_shift_toggle,grp_led:scroll,lv3:ralt_switch_multikey"
    else
      # For US keyboard we just define the Compose Key as before:
      XKBOPTIONS="lv3:ralt_switch_multikey"
    fi
  fi
  mkdir -p /mnt/overlay/etc/X11/xorg.conf.d
  echo > /mnt/overlay/etc/X11/xorg.conf.d/30-keyboard.conf
  cat <<EOT >> /mnt/overlay/etc/X11/xorg.conf.d/30-keyboard.conf
Section "InputClass"
  Identifier "keyboard-all"
  MatchIsKeyboard "on"
  MatchDevicePath "/dev/input/event*"
  Driver "evdev"
  Option "XkbLayout" "$XKBLAYOUT"
EOT
  if [ -z "$XKBVARIANT" ]; then
    cat <<EOT >> /mnt/overlay/etc/X11/xorg.conf.d/30-keyboard.conf
  #Option "XkbVariant" "$XKBVARIANT"
EOT
  else
    cat <<EOT >> /mnt/overlay/etc/X11/xorg.conf.d/30-keyboard.conf
  Option "XkbVariant" "$XKBVARIANT"
EOT
  fi
  cat <<EOT >> /mnt/overlay/etc/X11/xorg.conf.d/30-keyboard.conf
  Option "XkbOptions" "$XKBOPTIONS"
EndSection
EOT

  if [ ! -z "$LOCALE" ]; then
    # Configure custom locale:
    echo "${MARKER}:  Switching to '$LOCALE' locale"
    sed -i -e "s/^ *export LANG=.*/export LANG=${LOCALE}/" /mnt/overlay/etc/profile.d/lang.sh
    echo "LANG=${LOCALE}" > /mnt/overlay/etc/locale.conf
  fi

  if [ ! -z "$TZ" -a -f /mnt/overlay/usr/share/zoneinfo/${TZ} ]; then
    # Configure custom timezone:
    echo "${MARKER}:  Configuring timezone '$TZ'"
    rm -f /mnt/overlay/etc/localtime
    ln -s /usr/share/zoneinfo/${TZ} /mnt/overlay/etc/localtime
    rm -f /mnt/overlay/etc/localtime-copied-from
    # Configure the hardware clock to be interpreted as localtime and not UTC:
    cat <<EOT > /mnt/overlay/etc/hardwareclock
# /etc/hardwareclock
#
# Tells how the hardware clock time is stored.
# You should run timeconfig to edit this file.
localtime
EOT
    # QT5 expects "/etc/localtime" to be a symlink. Slackware's file is a real
    # file so QT5 fails to determine the timezone and falls back to UTC. Fix:
    echo ${TZ} > /mnt/overlay/etc/timezone

    # KDE4 and Plasma5 user timezone re-configuration:
    if [ -f /mnt/overlay/home/${LIVEUID}/.kde/share/config/ktimezonedrc ]; then
      sed -i -e "s%^LocalZone=.*%LocalZone=${TZ}%" \
        /mnt/overlay/home/${LIVEUID}/.kde/share/config/ktimezonedrc
    fi
    if [ -f /mnt/overlay/home/${LIVEUID}/.config/ktimezonedrc ]; then
      sed -i -e "s%^LocalZone=.*%LocalZone=${TZ}%" \
        /mnt/overlay/home/${LIVEUID}/.config/ktimezonedrc
    fi
  fi

  if [ -n "$LIVEPW" ] && [ "$LIVEPW" != "${DEFPW}" ]; then
    # User entered a custom live password on the boot commandline:
    echo "${MARKER}:  Changing password for user '${LIVEUID}'."
    chroot /mnt/overlay /usr/sbin/chpasswd <<EOPW
${LIVEUID}:${LIVEPW}
EOPW
  elif [ -z "$LIVEPW" ]; then
    # User requested an empty live password:
    echo "${MARKER}:  Removing password for user '${LIVEUID}'."
    chroot /mnt/overlay /usr/bin/passwd -d ${LIVEUID}
  fi

  if [ -n "$ROOTPW" ] && [ "$ROOTPW" != "${DEFPW}" ]; then
    # User entered a custom root password on the boot commandline:
    echo "${MARKER}:  Changing password for user 'root'."
    chroot /mnt/overlay /usr/sbin/chpasswd <<EOPW
root:${ROOTPW}
EOPW
  elif [ -z "$ROOTPW" ]; then
    # User requested an empty root password:
    echo "${MARKER}:  Removing password for user 'root'."
    chroot /mnt/overlay /usr/bin/passwd -d root
  fi

  if [ ! -z "$HNMAC" -a "$HNMAC_ALLOWED" = "YES" ]; then
    # We are booting from the network, give it a unique hostname:
    if [ -z "$LIVE_HOSTNAME" ]; then
      LIVE_HOSTNAME="@DARKSTAR@-${HNMAC}"
    else
      LIVE_HOSTNAME="${LIVE_HOSTNAME}-${HNMAC}"
    fi
  fi

  if [ -z "$LIVE_DOMAIN" ]; then
    # No custom domain on the boot commandline:
    LIVE_DOMAIN="home.arpa"
  fi

  if [ ! -z "$LIVE_HOSTNAME" ]; then
    # User entered a custom hostname on the boot commandline:
    echo "${MARKER}:  Changing hostname to '$LIVE_HOSTNAME'."
    echo "${LIVE_HOSTNAME}.${LIVE_DOMAIN}" > /mnt/overlay/etc/HOSTNAME
    if [ -f /mnt/overlay/etc/NetworkManager/NetworkManager.conf ]; then
      sed -i -e "s/^hostname=.*/hostname=${LIVE_HOSTNAME}/" \
        /mnt/overlay/etc/NetworkManager/NetworkManager.conf
    fi
    sed -i -e "s/^\(127.0.0.1\t*\)@DARKSTAR@.*/\1${LIVE_HOSTNAME}.${LIVE_DOMAIN} ${LIVE_HOSTNAME}/" /mnt/overlay/etc/hosts
  fi

  if [ -n "$NFSHOST" ]; then
    if [ -s $(get_dhcpcd_pid $INTERFACE) ]; then
      # Ensure that dhcpcd will find its configuration:
      mount --bind /var/lib/dhcpcd /mnt/overlay/var/lib/dhcpcd
      if [ -d /run/dhcpcd ]; then
        mkdir -p /mnt/overlay/run/dhcpcd
        mount --bind /run/dhcpcd /mnt/overlay/run/dhcpcd
      fi
      cp -a /run/dhcpcd* /run/${INTERFACE}.pid /mnt/overlay/run/
      cat /etc/resolv.conf > /mnt/overlay/etc/resolv.conf

      # Disable NetworkManager:
      chmod -x /mnt/overlay/etc/rc.d/rc.networkmanager

      # De-configure rc.inet1:
      cat <<EOT > /mnt/overlay/etc/rc.d/rc.inet1.conf
IFNAME[0]="$INTERFACE"
IPADDR[0]=""
NETMASK[0]=""
USE_DHCP[0]=""
DHCP_HOSTNAME[0]=""
GATEWAY=""
DEBUG_ETH_UP="no"
EOT
    fi
  fi

  # Tweaks:
  for TWEAK in $(echo $TWEAKS |tr ',' ' '); do 
    if [ "$TWEAK" = "nga" ]; then
      # Disable glamor 2D acceleration (QEMU needs this):
      cat <<EOT > /mnt/overlay/etc/X11/xorg.conf.d/20-noglamor.conf
Section "Device"
  Identifier "modesetting"
  Driver "modesetting"
  Option "AccelMethod" "none"
EndSection
EOT
    elif [ "$TWEAK" = "nsh" ]; then
      SPH=0
    elif [ "$TWEAK" = "tpb" ]; then
      # Enable scrolling with TrackPoint while pressing the middle mouse button.
      # Note: if this does not work for your TrackPoint,
      # replace "TPPS/2 IBM TrackPoint" with the name found in "xinput --list"
      cat <<EOT > /mnt/overlay/etc/X11/xorg.conf.d/20-trackpoint.conf
Section "InputClass"
        Identifier      "Trackpoint Wheel Emulation"
        MatchProduct    "TPPS/2 IBM TrackPoint|DualPoint Stick|Synaptics Inc. Composite TouchPad / TrackPoint|ThinkPad USB Keyboard with TrackPoint|USB Trackpoint pointing device|Composite TouchPad / TrackPoint"
        MatchDevicePath "/dev/input/event*"
        Option          "Emulate3Buttons"       "true"
        Option          "EmulateWheel"          "true"
        Option          "EmulateWheelTimeout"   "200"
        Option          "EmulateWheelButton"    "2"
        Option          "XAxisMapping"          "6 7"
        Option          "YAxisMapping"          "4 5"
EndSection
EOT
    elif [ "$TWEAK" = "syn" ]; then
      # Enable syndaemon for better management of Synaptics touchpad.
      mkdir -p /mnt/overlay/etc/xdg/autostart
      cat <<EOT > /mnt/overlay/etc/xdg/autostart/syndaemon.desktop 
[Desktop Entry]
Version=1.0
Name=Synaptics deamon
Comment=Enable proper communication with Synaptics touchpad
Exec=syndaemon -d -t -k -i 1
Terminal=false
Type=Application
Categories=
GenericName=
X-GNOME-Autostart-Phase=Initialization
X-KDE-autostart-phase=1
X-MATE-Autostart-Phase=Initialization
EOT
      # Extend what's in /usr/share/X11/xorg.conf.d/50-synaptics.conf
      cat <<EOT > /mnt/overlay/etc/X11/xorg.conf.d/50-synaptics.conf
# Use "synclient -l" to see all available options
# Use "man synaptics" for details about what the options do
Section "InputClass"
        Identifier "touchpad"
        Driver "synaptics"
        MatchDevicePath "/dev/input/event*"
        MatchIsTouchpad "on"
        Option "TapButton1" "1"
        Option "TapButton2" "2"
        Option "TapButton3" "3"
        Option "VertTwoFingerScroll"   "1"
        Option "HorizTwoFingerScroll"  "1"
        Option "VertEdgeScroll"        "1"
EndSection
EOT
    elif [ "$TWEAK" = "ssh" ]; then
      # Enable SSH daemon (disabled by default for security reasons):
      chmod +x /mnt/overlay/etc/rc.d/rc.sshd
    fi
  done # End Tweaks.

  # After parsing the tweaks, we know what to do with freetype's rendering:
  if [ ! -f /mnt/overlay/etc/profile.d/freetype.sh ]; then
    # Old freetype - disable sub-pixel hinting:
    SPH=0
  else
    # First, remove anything about sub-pixel hinting that could be enabled,
    # then decide what to do:
    sed -e 's/^ *[^# ]/#&/' -i /mnt/overlay/etc/profile.d/freetype.sh
    sed -e 's/^ *[^# ]/#&/' -i /mnt/overlay/etc/profile.d/freetype.csh
    rm -f /mnt/overlay/etc/fonts/conf.d/10-hinting-slight.conf
    rm -f /mnt/overlay/etc/fonts/conf.d/11-lcdfilter-default.conf
    rm -f /mnt/overlay/home/${LIVEUID}/.Xresources
  fi
  if [ $SPH -eq 1 ]; then
    # Enable the new v40 interpreter in freetype (bash and c-shell):
    cat <<EOT >> /mnt/overlay/etc/profile.d/freetype.sh
export FREETYPE_PROPERTIES="truetype:interpreter-version=40"
EOT
    cat <<EOT >> /mnt/overlay/etc/profile.d/freetype.csh
setenv FREETYPE_PROPERTIES "truetype:interpreter-version=40"
EOT
    # Adapt the font configuration:
    ln -s /etc/fonts/conf.avail/10-hinting-slight.conf /mnt/overlay/etc/fonts/conf.d/
    ln -s /etc/fonts/conf.avail/11-lcdfilter-default.conf /mnt/overlay/etc/fonts/conf.d/
    cat <<EOT > /mnt/overlay/home/${LIVEUID}/.Xresources
Xft.dpi: 96
Xft.antialias: 1
Xft.hinting: 1
Xft.hintstyle: hintslight
Xft.lcdfilter: lcddefault
Xft.rgba: rgb
Xft.autohint: 0
EOT
    chroot /mnt/overlay/ chown ${LIVEUID}:users /home/${LIVEUID}/.Xresources
  elif [ -f /mnt/overlay/etc/profile.d/freetype.sh ]; then
    # Explicitly configure the non-default old v35 interpreter in freetype:
    cat <<EOT >> /mnt/overlay/etc/profile.d/freetype.sh
export FREETYPE_PROPERTIES="truetype:interpreter-version=35"
EOT
    cat <<EOT >> /mnt/overlay/etc/profile.d/freetype.csh
setenv FREETYPE_PROPERTIES "truetype:interpreter-version=35"
EOT
  fi # End Sub-Pixel Hinting

  # Blacklist kernel modules if requested:
  if [ ! -z "$BLACKLIST" ]; then
    mkdir -p /mnt/overlay/etc/modprobe.d
    echo "#Slackware Live blacklist" > /mnt/overlay/etc/modprobe.d/BLACKLIST-live.conf
    for kernelmod in $(echo $BLACKLIST |tr ',' ' '); do
      echo "blacklist $kernelmod" >> /mnt/overlay/etc/modprobe.d/BLACKLIST-live.conf
    done
  fi

  # Find out if the user enabled any optional/addon kernel modules:
  RUN_DEPMOD=0
  for MOD in $(cat /sys/block/loop*/loop/backing_file |grep -E "optional|addons")
  do
    if [ -d /mnt/live/modules/$(mod_base $MOD)/lib/modules/$(uname -r)/ ]
    then
      # Found kernel modules directory; we need to make a 'depmod' call.
      RUN_DEPMOD=1
    fi
  done
  if [ $RUN_DEPMOD -eq 1 ]; then
    # This costs a few seconds in additional boot-up time unfortunately:
    echo "${MARKER}:  Additional kernel module(s) found... need a bit"
    chroot /mnt/overlay /sbin/depmod -a
  fi
  unset RUN_DEPMOD

  # Delete ALSA state file, the Live OS may be booted on different computers:
  rm -f /mnt/overlay/var/lib/alsa/asound.state

  # In case of network boot, do not kill the network, umount NFS prematurely
  #  or stop udevd on shutdown:
  if [ -n "$NFSHOST" ]; then
    for RUNLVL in 0 6 ; do 
      sed -i /mnt/overlay/etc/rc.d/rc.${RUNLVL} \
        -e "/on \/ type nfs/s%grep -q 'on / type nfs'%egrep -q 'on / type (nfs|tmpfs)'%" \
        -e "s%'on / type nfs4'%& -e 'on / type overlay'%" \
        -e '/umount.*nfs/s/nfs,//' \
        -e 's/rc.udev force-stop/rc.udev stop/' \
        -e 's/$(pgrep mdmon)/& $(pgrep udevd)/'
    done
  fi

  # Copy contents of rootcopy directory (may be empty) to overlay:
  cp -af /mnt/media/${LIVEMAIN}/rootcopy/* /mnt/overlay/ 2>/dev/null

  [ $DEBUG -gt 3 ] && rescue "DEBUG SHELL"

  # --------------------------------------------------------------------- #
  #                     SLACKWARE LIVE - !END!                            #
  # --------------------------------------------------------------------- #

  # Minimal changes to the original Slackware init follow:

  # Switch to real root partition:
  /sbin/udevadm settle --timeout=10
  echo 0x0100 > /proc/sys/kernel/real-root-dev

  # Re-mount the overlay read-only: 
  mount -o remount,ro /mnt/overlay 2>/dev/null

  if [ ! -r /mnt/overlay/${INIT} ]; then
    echo "ERROR:  No ${INIT} found on rootdev (or not mounted).  Trouble ahead."
    echo "        You can try to fix it. Type 'exit' when things are done." 
    echo
    /bin/sh
  fi
else
  rescue
fi

# Need to make sure OPTIONS+="db_persist" exists for all dm devices
# That should be handled in /sbin/mkinitrd now
/sbin/udevadm info --cleanup-db
/sbin/udevadm control --exit

unset ERR
umount /proc 2>/dev/null
umount /sys 2>/dev/null
umount /run 2>/dev/null

echo "${MARKER}:  Slackware Live system is ready."
echo "${MARKER}:  exiting"

exec switch_root /mnt/overlay $INIT $RUNLEVEL
