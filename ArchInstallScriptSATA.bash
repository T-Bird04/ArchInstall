#!/bin/bash
# ^ shebang for bash

#Enable stop on error
set -euo pipefail

#Enable terminal input
exec </dev/tty

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
name="Swap", size=32G, type=S
name="Root", size=+, type=L
EOF

#Format partitions
mkfs.fat -F 32 /dev/sda1 #EFI Boot parition is FAT32
mkfs.btrfs -f /dev/sda3 #Root partition is Btrfs

#Format swap partition
mkswap /dev/sda2

#Encrypt partitions
cryptsetup luksFormat --type luks2 /dev/sda2 --Key-File /password.txt
cryptsetup luksFormat --type luks2 /dev/sda3 --Key-File /password.txt

#Open encrypted partitions
cryptsetup open --type luks2 /dev/sda2 --Key-File /password.txt
cryptsetup open --type luks2 /dev/sda3 --Key-File /password.txt


#Mount btrfs partition
mount /dev/sda3 /mnt #Mount Root


#Enable swap partition
swapon /dev/sda2




#Create subvolumes for use with snapper
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots

#Unmount Btrfs partition and mount subvolumes and boot partition
umount /mnt
mount -o subvol=@,compress=zstd,noatime /dev/sda3 /mnt
mkdir -p /mnt/home
mount -o subvol=@home,compress=zstd,noatime /dev/sda3 /mnt/home
mkdir -p /mnt/.snapshots
mount -o subvol=@snapshots,compress=zstd,noatime /dev/sda3 /mnt/.snapshots
mount --mkdir /dev/sda1 /mnt/boot

#Create package bundles
CORE_PACKAGES=(
base
linux
linux-firmware)

HARDWARE_PACKAGES=(
amd-ucode
mesa
lib32-mesa
vulkan-radeon
vulkan-icd-loader
lib32-vulkan-icd-loader)

SERVICE_PACKAGES=(
nftables
iptables-nft
ufw
networkmanager
sudo
inotify-tools
curl)

AUDIO_PACKAGES=(
pipewire
wireplumber
pipewire-pulse
pipewire-alsa
rtkit)

FILE_PACKAGES=(
btrfs-progs
dosfstools
man-db 
man-pages
texinfo
efibootmgr
snapper
snap-pac
btrfs-assistant)

PROGRAM_PACKAGES=(
micro
neovim
firefox
steam
lutris
wine
winetricks)

BOOTLOADER_PACKAGES=(
systemdgenie
systemd-ukify
mkinitcpio
cryptsetup
sbctl
tpm2-tss
tpm2-tools
)

DESKTOP_PACKAGES=(
plasma-meta
plasma-wayland-session
plasma-firewall
sddm)

#Install core packages
pacstrap -K /mnt "${CORE_PACKAGES[@]}"  

#Create fstab file
genfstab -U /mnt >> /mnt/etc/fstab

#Update pacman.conf
cp /etc/pacman.conf /mnt/etc/pacman.conf

#Enter chroot
arch-chroot /mnt <<CHROOT_EOF

#Set up user time
ln -sf /usr/share/zoneinfo/America/Chicago /etc/localtime
hwclock --systohc

#Set up localization
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

#Install extra packages
pacman -S --noconfirm ${HARDWARE_PACKAGES[@]} ${SERVICE_PACKAGES[@]} ${AUDIO_PACKAGES[@]} ${FILE_PACKAGES[@]} ${PROGRAM_PACKAGES[@]} ${BOOTLOADER_PACKAGES[@]} ${DESKTOP_PACKAGES[@]}

#Set up systemd-boot
bootctl install

#Enable network manager
systemctl enable NetworkManager

#Enable KDE Plasma desktop
systemctl enable sddm

CHROOT_EOF

#Let user know script is done
echo "Install script finished"
