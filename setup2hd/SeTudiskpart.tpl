#!/bin/sh

# The script defaults to curses dialog but Xdialog is a good alternative:
DIALOG=${DIALOG:-"dialog"}

TMP=/var/log/setup/tmp
if [ ! -d $TMP ]; then
  mkdir -p $TMP
fi

  # If we do not find any useful disks at all, we must bail:
  if [ -z "$(lsblk -a -o NAME,SIZE,RM,RO,TYPE,MODEL |tr -s '[:blank:]' ' ' |grep '0 *0 *disk' | grep -v '^ram')" ]; then
    ${DIALOG} --backtitle "@CDISTRO@ Linux Setup (Live Edition)" \
     --title "NO HARD DRIVE DETECTED" \
     --msgbox "This machine appears not to have any hard drives installed.\
This setup will not work. Please add a hard drive to the computer first." 10 64
    exit 1
  fi

  # Generate a list of local hard drives we can write to:
  rm -f $TMP/tempscript
  cat <<EOT > $TMP/tempscript
${DIALOG} --stdout \\
  --title "SELECT DISK DRIVES" \\
  --backtitle "Creating Linux, swap and EFI partitions" \\
  --checklist "Select from available drives.\nA disk partitioning utility \\
will be presented for any drive you select here:" \\
  19 0 9 \\
EOT
  lsblk -a -o NAME,SIZE,RM,RO,TYPE,MODEL | \
    tr -s '[:blank:]' ' ' | grep '0 *0 *disk' | grep -v '^ram' | \
    while read LINE ; do
      DISKATTR=($LINE)
      DISKVENDOR="${DISKATTR[@]:5}"
      if [ -z "${DISKVENDOR}" ]; then
        DISKVENDOR="UnknownVendor"
      fi
      echo "\"/dev/${DISKATTR[0]}\" \"${DISKATTR[1]}: ${DISKVENDOR}\" off \\" >> $TMP/tempscript
    done
  echo '2>&1 1>$TMP/availdisks' >> $TMP/tempscript

  # Loop until the user makes a choice:
  while [ 0 ]; do
    source $TMP/tempscript
    if [ ! $? = 0 ] || [ ! -s $TMP/availdisks ]; then
      # Canceled the dialog, or did not select anything:
      rm -f $TMP/availdisks
    else
      # We got an answer:
      for DISKDRIVE in $(cat $TMP/availdisks) ; do
        # Determine which disk partitioning tool to use:
        if gdisk -l $DISKDRIVE |tr -s '[:blank:]' ' ' |grep -q "MBR: MBR only" ; then
          PARTTOOL=cfdisk
        else
          PARTTOOL=cgdisk
        fi
        # Now let the user create her partitions:
        $PARTTOOL $DISKDRIVE
      done
      break
    fi
  done
  # We should have partitions now, so re-run probe and collect that list:
  probe -l 2> /dev/null | grep -E 'Linux$' | sort 1> $TMP/SeTplist 2> /dev/null

