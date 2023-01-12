# This script is sourced from setup2hd.

# The script defaults to curses dialog but Xdialog is a good alternative:
DIALOG=${DIALOG:-"dialog"}

 # Slackware installation routine as taken from original 'setup':
 if [ "$MAINSELECT" = "INSTALL" ]; then
  if [ ! -r $TMP/SeTSERIES -o ! -r $TMP/SeTsource -o ! -r $TMP/SeTnative ]; then
   ${DIALOG} --title "CANNOT INSTALL SOFTWARE YET" --msgbox "\
\n\
Before you can install software, complete the following tasks:\n\
\n\
1. Select your source media.\n\
2. Set up your target Linux partition(s).\n\
3. Select which software categories to install.\n\
\n\
You may also optionally remap your keyboard and set up your\n\
swap partition(s). \n\
\n\
Press ENTER to return to the main menu." 16 68
   continue
  fi
  SERIES="`cat $TMP/SeTSERIES`"
  SOURCE_DEVICE="`cat $TMP/SeTsource`"
  IGNORE_TAGFILES=""
  while [ 0 ]; do
   ${DIALOG} --title "SELECT PROMPTING MODE" --default-item "terse" --menu \
   "Now you must select the type of prompts you'd like to see during the \
installation process. If you have the drive space, the 'full' option \
is quick, easy, and by far the most foolproof choice. The 'newbie' \
mode provides the most information but is much more time-consuming \
(presenting the packages one by one) than the menu-based choices. \
Otherwise, you can pick packages from menus \
using 'expert' or 'menu' mode. Which type of prompting would you like \
to use?" \
   20 76 7 \
   "full" "Install everything (9+ GB of software, RECOMMENDED!)" \
   "terse" "Like 'full', but display one line per package during install" \
   "menu" "Choose individual packages from interactive menus" \
   "expert" "This is actually the same as the \"menu\" option" \
   "newbie" "Use verbose prompting (the X series takes one year)" \
   "custom" "Use custom tagfiles in the package directories" \
   "tagpath" "Use tagfiles in the subdirectories of a custom path" \
   "help" "Read the prompt mode help file" 2> $TMP/SeTpmode
   if [ ! $? = 0 ]; then
    rm -f $TMP/SeTpmode
    exit
   fi
   MODE="`cat $TMP/SeTpmode`"
   rm -f $TMP/SeTtagext
   if [ "$MODE" = "help" ]; then
    ${DIALOG} --title "PROMPT MODE HELP" --exit-label OK --textbox "/usr/lib/setup/PROMPThelp" 19 65
   fi
   if [ "$MODE" = "tagpath" ]; then
    ${DIALOG} --title "PROVIDE A CUSTOM PATH TO YOUR TAGFILES" --inputbox \
    "If you're installing from CD or DVD, it's impossible to edit the \
tagfiles that are in the package directories. In this case, you might \
want to provide a path to your custom tagfiles. As an example, you \
could create a /tagfiles directory and mount a floppy disk containing \
the tagfiles on that directory. Then you'd enter '/tagfiles' at the \
prompt below. The setup program will look for your tagfile in \
SUBDIRECTORIES of the path you provide, such as /tagfiles/a, \
/tagfiles/ap, /tagfiles/d, and so on. You only need to provide a \
subdirectory and tagfile for the first disk of each series to be \
installed. If a custom tagfile is not found at the path you provide, \
setup will revert to the default tagfiles. Please enter the path to your \
custom tagfiles:" \
    19 71 2> $TMP/SeTtagpath
    if [ ! $? = 0 ]; then
     continue
    fi
    if [ -r $TMP/SeTtagpath ]; then
     if [ "`cat $TMP/SeTtagpath`" = "" ]; then
      rm -f $TMP/SeTtagpath
     elif [ ! -d "$(cat $TMP/SeTtagpath)" ]; then
       ${DIALOG} --title "NOT A VALID DIRECTORY" --msgbox \
"Sorry, but the $(cat $TMP/SeTtagpath) directory could not be located. \
Press ENTER to go back to the SELECT PROMPTING MODE menu." \
7 65
      rm -f $TMP/SeTtagpath
      continue
     fi
    fi
    break;
   fi
   if [ "$MODE" = "newbie" ]; then 
    ${DIALOG} --infobox "'newbie' prompt mode selected.  Using default tagfiles \
and verbose package prompting." 4 50
    break;
   fi 
   if [ "$MODE" = "custom" ]; then
    ${DIALOG} --title "ENTER CUSTOM EXTENSION" --inputbox "Now, enter the custom \
extension you have used for your tagfiles. This must be a valid MS-DOS format \
file extension consisting of a period followed by three characters. For \
example, I use '.pat'. You might see my tagfiles on your disks. :^)" \
12 60 2> $TMP/SeTtagext
    if [ ! $? = 0 ]; then
     continue
    fi
    if [ -r $TMP/SeTtagext ]; then
     if [ "`cat $TMP/SeTtagext`" = "" ]; then
      rm -f $TMP/SeTtagext
     fi
    fi
    ${DIALOG} --infobox "'custom' prompt mode selected. Using prompting defaults \
found in custom tagfiles." 4 50
    break;
   fi
   if [ "$MODE" = "full" ]; then
    IGNORE_TAGFILES="-ignore_tagfiles"
    ${DIALOG} --infobox "Full installation mode. Installing all software \
packages without prompting." 4 45
    break;
   fi
   if [ "$MODE" = "terse" ]; then
    setterm -background cyan -foreground black -blank 0
    clear
    IGNORE_TAGFILES="-ignore_tagfiles"
    echo
    echo
    echo "Full (terse display) installation mode."
    echo
    echo "A one-line description will be displayed as each package is installed."
    echo
    break;
   fi
   if [ "$MODE" = "menu" ]; then
    ${DIALOG} --infobox "'menu' prompt mode selected. Using interactive menus \
to choose subsystems of related packages." 4 60
    break;
   fi
   if [ "$MODE" = "expert" ]; then
    ${DIALOG} --infobox "'expert' prompt mode selected. Using interactive menus \
to choose packages individually." 4 60
    break;
   fi 
  done
  export MAKETAG;
  sleep 1
  # On a new system, make /etc/mtab a symlink to /proc/mounts:
  if [ ! -r $T_PX/etc/mtab ]; then
    mkdir -p $T_PX/etc
    ( cd $T_PX/etc ; ln -sf /proc/mounts mtab )
  fi
  # Do the package install:
  if [ -r $TMP/SeTCDdev ]; then # only try to remount media if it's a CD/DVD
    slackinstall --device `cat $TMP/SeTCDdev` --promptmode $MODE --srcpath `cat $TMP/SeTDS` --mountpoint /var/log/mount --target $T_PX --series $SERIES
  elif [ -r $TMP/SeTremotesvr ]; then
    slackinstall --device noremount --promptmode $MODE --srcpath `cat $TMP/SeTDS` --mountpoint /var/log/mount --target $T_PX --series $SERIES --net `cat $TMP/SeTremotesvr`
  else
    slackinstall --device noremount --promptmode $MODE --srcpath `cat $TMP/SeTDS` --mountpoint /var/log/mount --target $T_PX --series $SERIES
  fi
  if [ $MODE = terse ]; then
    # Let's pause a moment and then restore the terminal settings
    sleep 1
    setterm -background black -foreground white -blank 0
  fi
  MAINSELECT="CONFIGURE"
 fi
 # End Slackware installation routine.
