#
# GRUB menu template for Slackware Live Edition
#
set default=0
set timeout=20

# Slackware Live defaults, can be changed in submenus:
if [ -z "$sl_kbd" ]; then
  set sl_kbd="@KBD@"
  export sl_kbd
fi
if [ -z "$sl_tz" ]; then
  set sl_tz="@TZ@"
  export sl_tz
fi
if [ -z "$sl_lang" ]; then
  set sl_lang="@LANDSC@"
  export sl_lang
fi
if [ -z "$sl_locale" ]; then
  set sl_locale="@LOCALE@"
  export sl_locale
fi

# Check whether we are in a Secure Boot scenario:
if [ "x$lockdown" != "x" ]; then
  set check_signatures=enforce
  export check_signatures
fi

# Determine whether we can show a graphical themed menu:
insmod font
if loadfont $prefix/theme/dejavusansmono12.pf2 ; then
  loadfont $prefix/theme/dejavusansmono10.pf2
  loadfont $prefix/theme/dejavusansmono5.pf2
  set gfxmode=1024x768,800x600,640x480,auto
  export gfxmode
  # (U)EFI requirement: must support all_video:
  insmod all_video
  insmod gfxterm
  insmod gfxmenu
  terminal_output gfxterm
  insmod gettext
  insmod png
  set theme=$prefix/theme/liveslak.txt
  export theme
fi

menuentry "Start @CDISTRO@@DIRSUFFIX@ @SL_VERSION@ @LIVEDE@ liveslak-@VERSION@ ($sl_lang)" --hotkey b {
  linux ($root)/boot/generic @KAPPEND@ load_ramdisk=1 prompt_ramdisk=0 rw printk.time=0 kbd=$sl_kbd tz=$sl_tz locale=$sl_locale xkb=$sl_xkb
  initrd ($root)/boot/initrd.img
}

submenu "Non-@ULANG@ Keyboard selection" --hotkey k {
  configfile $prefix/kbd.cfg
}

submenu "Non-@ULANG@ Language selection" --hotkey l {
  configfile $prefix/lang.cfg
}

submenu "Non-@ULANG@ Timezone selection" --hotkey t {
  configfile $prefix/tz.cfg
}

menuentry "Memory test with memtest86+" {
  linux ($root)/boot/memtest
}

menuentry "Help on boot parameters" --hotkey h { 
  set pager=1 
  cat $prefix/help.txt 
  unset pager 
} 

@C2RMS@menuentry "Console OS in RAM ($sl_lang)" --hotkey c {
@C2RMS@  linux ($root)/boot/generic @KAPPEND@ load_ramdisk=1 prompt_ramdisk=0 rw printk.time=0 kbd=$sl_kbd tz=$sl_tz locale=$sl_locale xkb=$sl_xkb toram=core 3
@C2RMS@  initrd ($root)/boot/initrd.img
@C2RMS@}

