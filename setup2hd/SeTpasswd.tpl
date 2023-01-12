# The script defaults to curses dialog but Xdialog is a good alternative:
DIALOG=${DIALOG:-"dialog"}

#!/bin/sh
# Liveslak replacement for Slackware's SeTpassword script.

TMP=/var/log/setup/tmp
if [ ! -d $TMP ]; then
  mkdir -p $TMP
fi
T_PX="$(cat $TMP/SeTT_PX)"

# Check for root password:
if [ "$(cat $T_PX/etc/shadow | grep 'root:' | cut -f 2 -d :)" != "" ]; then
  # Root password has been set, nothing further to be done.
  exit 0
fi

# No root password has been set yet, which means no user was created either.

# Set up a user account,
if [ -r $TMP/SeTlive ]; then
  # We will only configgure su access when installing a Live OS:
  SUTEXT="\nYour account will be added to sudoers and suauth."
else
  SUTEXT=""
fi
${DIALOG} --title "@UDISTRO@ (@LIVEDE@) USER CREATION" \
 --backtitle "@CDISTRO@ Linux Setup (Live Edition)" \
 --msgbox "You will first get the chance to create your user account, \
and set its password.${SUTEXT}\n\n\
After that, you will be asked to set the root password." 11 55
# This will set UFULLNAME, UACCOUNT and USHELL variables:
SeTuacct 2>&1 1> $TMP/temppasswd
if [ $? = 0 ]; then
  # User filled out the form, so let's get the results for
  # UFULLNAME, UACCOUNT, UACCTNR and USHELL:
  source $TMP/temppasswd
  rm -f $TMP/temppasswd
  # Set a password for the new account:
  UPASS=$(SeTupass $UACCOUNT)
  # Create the account and set the password:
  chroot ${T_PX} /usr/sbin/useradd -c "$UFULLNAME" -g users -G wheel,audio,cdrom,floppy,plugdev,video,power,netdev,lp,scanner,dialout,games,disk,input -u ${UACCTNR} -d /home/${UACCOUNT} -m -s ${USHELL} ${UACCOUNT}
  echo "${UACCOUNT}:${UPASS}" | chroot ${T_PX} /usr/sbin/chpasswd
  unset UPASS
fi # End user creation

# Finally, set the root password:
UPASS=$(SeTupass root)
echo "root:${UPASS}" | chroot ${T_PX} /usr/sbin/chpasswd
unset UPASS
