#!/bin/bash
# ^ shebang for bash

#Enable stop on error
set -euo pipefail

#Create secure boot keys
sbctl create-keys

#Enroll the keys (--microsoft allows for Windows dual boot)
sbctl enroll-keys --microsoft -f

#Create UKI by re-downloading the linux kernel (sbctl will auto sign)
pacman -S --noconfirm linux

#Sign bootloader
sbctl sign -s /boot/EFI/systemd/systemd-bootx64.efi
