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

#Create disk partitions (First is EFI Boot, second is swap, and third is Linux Root)
sfdisk /dev/sda <<EOF
label: gpt
name="Boot", size=1G, type=U
name="Swap", size=32G, type=S
name="Root", size=+, type=L
EOF

#Encrypt root partition
cryptsetup luksFormat --type luks2 /dev/sda3

#Open encrypted root partition
cryptsetup open --type luks2 /dev/sda3 cryptroot

#Format boot partition
mkfs.fat -F 32 /dev/sda1 #EFI Boot parition is FAT32

#Format root partition
mkfs.btrfs -f /dev/mapper/cryptroot

#Mount root partition
mount /dev/mapper/cryptroot /mnt #Mount Root

#Create subvolumes for use with snapper
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots

#Unmount root partition and mount subvolumes and boot partition
umount /mnt
mount -o subvol=@,compress=zstd,noatime /dev/mapper/cryptroot /mnt
mkdir -p /mnt/home
mount -o subvol=@home,compress=zstd,noatime /dev/mapper/cryptroot /mnt/home
mkdir -p /mnt/.snapshots
mount -o subvol=@snapshots,compress=zstd,noatime /dev/mapper/cryptroot /mnt/.snapshots
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
lib32-vulkan-radeon
vulkan-icd-loader
lib32-vulkan-icd-loader)

SERVICE_PACKAGES=(
iptables
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

#Enable multilib in pacman confs
nano /etc/pacman.conf
cp /etc/pacman.conf /mnt/etc/pacman.conf

#Install packages
pacstrap -K /mnt ${CORE_PACKAGES[@]} ${HARDWARE_PACKAGES[@]} ${SERVICE_PACKAGES[@]} ${AUDIO_PACKAGES[@]} ${FILE_PACKAGES[@]} ${PROGRAM_PACKAGES[@]} ${BOOTLOADER_PACKAGES[@]} ${DESKTOP_PACKAGES[@]}

#Update fstab file
genfstab -U /mnt >> /mnt/etc/fstab

#Find UUID for swap partition
SWAP_PARTUUID=$(blkid -s PARTUUID -o value /dev/sda2)

#Encrypt swap with random key
cat > /mnt/etc/crypttab <<EOF
swap /dev/disk/by-partuuid/${SWAP_PARTUUID} /dev/urandom swap,cipher=aes-xts-plain64,size=512,sector-size=4096
EOF

#Update fstab for swap unencryption
cat >> /mnt/etc/fstab <<EOF
/dev/mapper/swap none swap defaults 0 0
EOF

#Enter chroot
arch-chroot /mnt <<CHROOT_EOF

#Create root password
passwd </dev/tty

#Set up user time
ln -sf /usr/share/zoneinfo/America/Chicago /etc/localtime
hwclock --systohc

#Set up localization
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

#Set up systemd-boot
bootctl install

#Enable network manager
systemctl enable NetworkManager

#Enable KDE Plasma desktop
systemctl enable sddm

#Create secure boot keys
sbctl create-keys

#Enroll the keys (--microsoft allows for Windows dual boot and -f provides OEM firmware certs)
sbctl enroll-keys --microsoft -f

#Configure mkinitcpio
nano /etc/mkinitcpio.conf </dev/tty

#Change Kernal-Install layout to UKI
nano /etc/kernel/install.conf </dev/tty

#Find UUID of root partition
ROOT_UUID=$(blkid -s UUID -o value /dev/sda3)

#Create kernel command line file
cat > /etc/kernel/cmdline <<EOF
rd.luks.name=${ROOT_UUID}=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw loglevel=3 quiet
EOF

#Configure ukify config file (Settings: [UKI]  SecureBootSigningTool=systemd-sbsign  SignKernel=true  SecureBootPrivateKey=/etc/kernel/secure-boot-private-key.pem  SecureBootCertificate=/etc/kernel/secure-boot-certificate.pem)
nano /etc/kernel/uki.conf </dev/tty

#Move key and cert to path in ukify conf
cp /var/lib/sbctl/keys/secure-boot-private-key.pem /etc/kernel/secure-boot-private-key.pem
cp /var/lib/sbctl/keys/secure-boot-certificate.pem /etc/kernel/secure-boot-certificate.pem

#Create UKI by adding the linux kernel (sbctl will auto sign)
kernel-install add-all

#Sign bootloader
sbctl sign -s /boot/EFI/systemd/systemd-bootx64.efi

#Enable sudo wheel group
visudo </dev/tty

#Create and configure user account
useradd -m -s /bin/bash Terrence
passwd Terrence </dev/tty
usermod -aG wheel Terrence

#Exit chroot
exit

CHROOT_EOF

#Let user know script is done
echo "Install script finished"
