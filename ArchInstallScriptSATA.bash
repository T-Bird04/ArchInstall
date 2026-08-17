#!/bin/bash
# ^ shebang for bash

#Enable stop on error
set -euo pipefail

#Verify proper UEFI 64 boot mode
if [[ ! -d /sys/firmware/efi ]]; then
    echo "System was not booted in UEFI mode."
    exit 1
fi

if [[ "$(cat /sys/firmware/efi/fw_platform_size)" != "64" ]]; then
    echo "64-bit UEFI firmware required."
    exit 1
fi

#Create disk partitions (First is EFI Boot and second is Linux Root)
sfdisk /dev/sda <<EOF
label: gpt
name="Boot", size=1G, type=U
name="Root", size=+, type=L
EOF

#Format paritions
mkfs.fat -F 32 /dev/sda1 #EFI Boot parition is FAT32
mkfs.btrfs -f /dev/sda2 #Root partition is Btrfs

#Mount btrfs partition
mount /dev/sda2 /mnt #Mount Root

#Create subvolumes for use with snapper
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots

#Unmount Btrfs partition and mount subvolumes and boot partition
umount /mnt
mount -o subvol=@,compress=zstd,noatime /dev/sda2 /mnt
mkdir -p /mnt/home
mount -o subvol=@home,compress=zstd,noatime /dev/sda2 /mnt/home
mkdir -p /mnt/.snapshots
mount -o subvol=@snapshots,compress=zstd,noatime /dev/sda2 /mnt/.snapshots
mount --mkdir /dev/sda1 /mnt/boot

#Enable multilib for 32-bit packages
sed -i '/^\[multilib\]/,/^Include/ s/^#//' /etc/pacman.conf
pacman -Syu

#Install packages
pacstrap -K /mnt base linux linux-firmware #Core Arch Packages
pacstrap -K /mnt amd-ucode mesa lib32-mesa vulkan-radeon vulkan-icd-loader lib32-vulkan-icd-loader #Hardware Packages	
pacstrap -K /mnt networkmanager sudo #Service Packages
pacstrap -K /mnt pipewire wireplumber pipewire-pulse pipewire-alsa rtkit #Audio Packages
pacstrap -K /mnt btrfs-progs dosfstools man-db man-pages texinfo efibootmanager snapper btrfs-assistant #Filesystem + Snapshot Packages
pacstrap -K /mnt micro neovim firefox steam lutris wine winetricks #Program Packages
pacstrap -K /mnt grub grub-btrfs #Bootloader Packages
pacstrap -K /mnt plasma-meta sddm #Desktop Enviornment Packages
			
#Create fstab file
genfstab -U /mnt >> /mnt/etc/fstab

#Set up root password
arch-chroot /mnt passwd

#Enter chroot
arch-chroot /mnt <<CHROOT_EOF

#Set up user time
ln -sf /usr/share/zoneinfo/America/Chicago /etc/localtime
hwclock --systohc

#Set up localization
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

#Set up GRUB boot manager
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

#Enable network manager
systemctl enable NetworkManager

#Enable KDE Plasma desktop
systemctl enable sddm

CHROOT_EOF

#Let user know script is done
echo "Install script finished"