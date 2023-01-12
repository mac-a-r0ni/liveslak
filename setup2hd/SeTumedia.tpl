#!/bin/sh

# The script defaults to curses dialog but Xdialog is a good alternative:
DIALOG=${DIALOG:-"dialog"}

TMP=/var/log/setup/tmp
if [ ! -d $TMP ]; then
  mkdir -p $TMP
fi

${DIALOG} --backtitle "Select Slackware installation source." \
--title "SOURCE MEDIA SELECTION" \
--default-item '4' --menu \
"Please select the media from which to install Slackware Linux:" \
11 70 4 \
"1" "Install Slackware from NFS (Network File System)" \
"2" "Install Slackware from FTP/HTTP server" \
"3" "Install Slackware from Samba share" \
"4" "Install @UDISTRO@ (@LIVEDE@) Live OS to disk" \
2> $TMP/media
if [ ! $? = 0 ]; then
 rm $TMP/media
 exit
fi

SOURCE_MEDIA="`cat $TMP/media`"
rm -f $TMP/media
if [ "$SOURCE_MEDIA" = "1" ]; then
 INSNFS
elif [ "$SOURCE_MEDIA" = "2" ]; then
 INSURL 
elif [ "$SOURCE_MEDIA" = "3" ]; then
 INSSMB 
elif [ "$SOURCE_MEDIA" = "4" ]; then
 touch $TMP/SeTlive
 touch $TMP/SeTsource
fi

