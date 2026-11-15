# mb81-audio
one-shot internal-speaker + audio installer for the 12-inch MacBook (Early 2015, MacBook8,1) on Debian / Ubuntu / Linux Mint.

   sudo ./mb81-audio.sh               install (then reboot once)
   sudo ./mb81-audio.sh --uninstall   remove everything, restore stock drivers
   sudo ./mb81-audio.sh --verify      after reboot: is the driver loaded, does audio flow?
   sudo ./mb81-audio.sh --rebuild     rebuild the DKMS modules for every installed kernel
   sudo ./mb81-audio.sh --fix-chime   only un-mute the EFI startup chime (see below)

   this is mostly vibe coded 
