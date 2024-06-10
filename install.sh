#!/bin/bash
#
# Arch Linux installation
#
# Bootable USB:
# - [Download](https://archlinux.org/download/) ISO and GPG files
# - Verify the ISO file: `$ pacman-key -v archlinux-<version>-dual.iso.sig`
# - Create a bootable USB with: `# dd if=archlinux*.iso of=/dev/sdX && sync`
#
# UEFI setup:
#
# - Set boot mode to UEFI, disable Legacy mode entirely.
# - Temporarily disable Secure Boot.
# - Make sure a strong UEFI administrator password is set.
# - Delete preloaded OEM keys for Secure Boot, allow custom ones.
# - Set SATA operation to AHCI mode.
#
# Run installation:
#
# - Connect to wifi via: `# iwctl station wlan0 connect WIFI-NETWORK`
# - Run: `# bash <(curl -sL https://git.io/maximbaz-install)`

set -uo pipefail
trap 's=$?; echo "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

exec 1> >(tee "stdout.log")
exec 2> >(tee "stderr.log" >&2)

export SNAP_PAC_SKIP=y

# Dialog
BACKTITLE="Arch Linux installation"

get_input() {
    title="$1"
    description="$2"

    input=$(dialog --clear --stdout --backtitle "$BACKTITLE" --title "$title" --inputbox "$description" 0 0)
    echo "$input"
}

get_password() {
    title="$1"
    description="$2"

    init_pass=$(dialog --clear --stdout --backtitle "$BACKTITLE" --title "$title" --passwordbox "$description" 0 0)
    : ${init_pass:?"password cannot be empty"}

    test_pass=$(dialog --clear --stdout --backtitle "$BACKTITLE" --title "$title" --passwordbox "$description again" 0 0)
    if [[ "$init_pass" != "$test_pass" ]]; then
        echo "Passwords did not match. Please try again." >&2
        get_password "$title" "$description"
    fi
    echo $init_pass
}

get_choice() {
    title="$1"
    description="$2"
    shift 2
    options=("$@")
    dialog --clear --stdout --backtitle "$BACKTITLE" --title "$title" --menu "$description" 0 0 0 "${options[@]}"
}

check_uefi_mode() {
    echo -e "\n### Checking UEFI boot mode"
    if [ ! -f /sys/firmware/efi/fw_platform_size ]; then
        echo >&2 "You must boot in UEFI mode to continue. Please restart your system in UEFI mode."
        exit 2
    else
        echo "UEFI boot mode confirmed."
    fi
}

setup_clock() {
    echo -e "\n### Setting up clock"
    timedatectl set-ntp true
    systemctl enable systemd-timesyncd.service
    systemctl start systemd-timesyncd.service
    if [ $? -eq 0 ]; then
        echo "Network time protocol enabled."
    else
        echo "Failed to enable network time protocol." >&2
        exit 1
    fi

    timedatectl set-local-rtc 0
    hwclock --systohc --utc
    if [ $? -eq 0 ]; then
        echo "System clock synchronized to UTC."
    else
        echo "Failed to synchronize system clock to UTC." >&2
        exit 1
    fi
}

install_tools() {
    echo -e "\n### Installing additional tools"
    if pacman -Sy --noconfirm --needed git reflector terminus-font dialog wget; then
        echo "Necessary tools installed successfully."
    else
        echo "Failed to install necessary tools. Check your network connection and try again." >&2
        exit 1
    fi
}

enable_parallel_downloads() {
    echo -e "\n### Enabling parallel downloads in pacman"
    echo "ParallelDownloads = 5" >> /etc/pacman.conf
}

setup_hidpi() {
    echo -e "\n### HiDPI screens"
    noyes=("Yes" "The font is too small" "No" "The font size is just fine")
    hidpi=$(get_choice "Font size" "Is your screen HiDPI?" "${noyes[@]}") || exit 1
    clear
    if [[ "$hidpi" == "Yes" ]]; then
        font="ter-132n"
        echo "HiDPI screen detected, setting large font."
    else
        font="ter-716n"
        echo "Standard DPI screen detected, setting normal font."
    fi
    setfont "$font"
}

get_user_input() {
    hostname=$(get_input "Hostname" "Enter hostname") || exit 1
    clear
    : ${hostname:?"hostname cannot be empty"}
    echo "Hostname set to $hostname."

    user=$(get_input "User" "Enter username") || exit 1
    clear
    : ${user:?"user cannot be empty"}
    echo "Username set to $user."

    password=$(get_password "User" "Enter password") || exit 1
    clear
    : ${password:?"password cannot be empty"}
    echo "Password set successfully."
}

select_disks() {
    devicelist=$(lsblk -dplnx size -o name,size | grep -Ev "boot|rpmb|loop" | tac | tr '\n' ' ')
    read -r -a devicelist <<< $devicelist

    device=$(get_choice "Installation" "Select installation disk" "${devicelist[@]}") || exit 1
    clear
    echo "Installation disk selected: $device."

    luks_header_device=$(get_choice "Installation" "Select disk to write LUKS header to" "${devicelist[@]}") || exit 1
    clear
    echo "LUKS header disk selected: $luks_header_device."
}

setup_fastest_mirrors() {
    echo -e "\n### Setting up fastest mirrors"
    if reflector --latest 30 --sort rate --save /etc/pacman.d/mirrorlist; then
        echo "Fastest mirrors set up successfully."
    else
        echo "Failed to set up the fastest mirrors. Check your network connection or try different mirrors." >&2
        exit 1
    fi
}

enable_reflector_timer() {
    echo -e "\n### Enabling Reflector timer"
    install -Dm644 systemd/reflector.service /mnt/etc/systemd/system/reflector.service
    install -Dm644 systemd/reflector.timer /mnt/etc/systemd/system/reflector.timer
    arch-chroot /mnt systemctl enable reflector.timer
    arch-chroot /mnt systemctl start reflector.timer
}

setup_firewall() {
    echo -e "\n### Setting up firewall"
    if pacman -Sy --noconfirm --needed nftables; then
        echo "nftables installed successfully."
    else
        echo "Failed to install nftables. Check your network connection and try again." >&2
        exit 1
    fi

    install -Dm644 etc/nftables.conf /mnt/etc/nftables.conf
    arch-chroot /mnt systemctl enable nftables
    arch-chroot /mnt systemctl start nftables
}

setup_partitions() {
    echo -e "\n### Setting up partitions"
    umount -R /mnt 2> /dev/null || true
    cryptsetup luksClose luks 2> /dev/null || true

    lsblk -plnx size -o name "${device}" | xargs -n1 wipefs --all
    sgdisk --clear "${device}" --new 1::-551MiB "${device}" --new 2::0 --typecode 2:ef00 "${device}"
    sgdisk --change-name=1:primary --change-name=2:ESP "${device}"

    part_root="$(ls ${device}* | grep -E "^${device}p?1$")"
    part_boot="$(ls ${device}* | grep -E "^${device}p?2$")"

    if [ "$device" != "$luks_header_device" ]; then
        cryptargs="--header $luks_header_device"
    else
        cryptargs=""
        luks_header_device="$part_root"
    fi

    echo -e "\n### Formatting partitions"
    mkfs.vfat -n "EFI" -F 32 "${part_boot}"
echo -n ${password} | cryptsetup luksFormat --type luks2 --pbkdf argon2id --iter-time 5000 --label luks $cryptargs "${part_root}"    echo -n ${password} | cryptsetup luksOpen $cryptargs "${part_root}" luks
    mkfs.btrfs -L btrfs /dev/mapper/luks
}

setup_btrfs_subvolumes() {
    echo -e "\n### Setting up BTRFS subvolumes"
    mount /dev/mapper/luks /mnt
    btrfs subvolume create /mnt/root
    btrfs subvolume create /mnt/home
    btrfs subvolume create /mnt/pkgs
    btrfs subvolume create /mnt/aurbuild
    btrfs subvolume create /mnt/archbuild
    btrfs subvolume create /mnt/docker
    btrfs subvolume create /mnt/logs
    btrfs subvolume create /mnt/temp
    btrfs subvolume create /mnt/swap
    btrfs subvolume create /mnt/snapshots
    umount /mnt

    mount -o noatime,nodiratime,compress=zstd,autodefrag,ssd,subvol=root /dev/mapper/luks /mnt
    mkdir -p /mnt/{mnt/btrfs-root,efi,home,var/{cache/pacman,log,tmp,lib/{aurbuild,archbuild,docker}},swap,.snapshots}
    mount "${part_boot}" /mnt/efi
    mount -o noatime,nodiratime,compress=zstd,autodefrag,ssd,subvol=/ /dev/mapper/luks /mnt/mnt/btrfs-root
    mount -o noatime,nodiratime,compress=zstd,autodefrag,ssd,subvol=home /dev/mapper/luks /mnt/home
    mount -o noatime,nodiratime,compress=zstd,autodefrag,ssd,subvol=pkgs /dev/mapper/luks /mnt/var/cache/pacman
    mount -o noatime,nodiratime,compress=zstd,autodefrag,ssd,subvol=aurbuild /dev/mapper/luks /mnt/var/lib/aurbuild
    mount -o noatime,nodiratime,compress=zstd,autodefrag,ssd,subvol=archbuild /dev/mapper/luks /mnt/var/lib/archbuild
    mount -o noatime,nodiratime,compress=zstd,autodefrag,ssd,subvol=docker /dev/mapper/luks /mnt/var/lib/docker
    mount -o noatime,nodiratime,compress=zstd,autodefrag,ssd,subvol=logs /dev/mapper/luks /mnt/var/log
    mount -o noatime,nodiratime,compress=zstd,autodefrag,ssd,subvol=temp /dev/mapper/luks /mnt/var/tmp
    mount -o noatime,nodiratime,compress=zstd,autodefrag,ssd,subvol=swap /dev/mapper/luks /mnt/swap
    mount -o noatime,nodiratime,compress=zstd,autodefrag,ssd,subvol=snapshots /dev/mapper/luks /mnt/.snapshots
}

configure_custom_repo() {
    echo -e "\n### Configuring custom repo"
    mkdir "/mnt/var/cache/pacman/${user}-local"
    march="$(uname -m)"

    if [[ "${user}" == "maximbaz" && "${hostname}" == "home-"* ]]; then
        wget -m -nH -np -q --show-progress --progress=bar:force --reject="${march}*" --cut-dirs=3 --include-directories="~maximbaz/repo/${march}" -P "/mnt/var/cache/pacman/${user}-local" "https://pkgbuild.com/~maximbaz/repo/${march}"
        rename -- 'maximbaz.' "${user}-local." "/mnt/var/cache/pacman/${user}-local"/*
    else
        repo-add "/mnt/var/cache/pacman/${user}-local/${user}-local.db.tar"
    fi

    if ! grep "${user}" /etc/pacman.conf > /dev/null; then
        cat >> /etc/pacman.conf << EOF
[${user}-local]
Server = file:///mnt/var/cache/pacman/${user}-local

[maximbaz]
Server = https://pkgbuild.com/~maximbaz/repo/${march}

[options]
CacheDir = /mnt/var/cache/pacman/pkg
CacheDir = /mnt/var/cache/pacman/${user}-local
EOF
    fi
}

install_packages() {
    echo -e "\n### Installing packages"
    if pacstrap -i /mnt maximbaz-base maximbaz-$(uname -m); then
        echo "Packages installed successfully."
    else
        echo "Failed to install packages. Check your network connection or mirror configuration and try again." >&2
        exit 1
    fi
}

generate_base_config() {
    echo -e "\n### Generating base config files"
    ln -sfT dash /mnt/usr/bin/sh

    cryptsetup luksHeaderBackup "${luks_header_device}" --header-backup-file /tmp/header.img
    luks_header_size="$(stat -c '%s' /tmp/header.img)"
    rm -f /tmp/header.img

    echo "cryptdevice=PARTLABEL=primary:luks:allow-discards cryptheader=LABEL=luks:0:$luks_header_size root=LABEL=btrfs rw rootflags=subvol=root quiet mem_sleep_default=deep" > /mnt/etc/kernel/cmdline

    echo "FONT=$font" > /mnt/etc/vconsole.conf
    genfstab -L /mnt >> /mnt/etc/fstab
    echo "${hostname}" > /mnt/etc/hostname
    echo "en_US.UTF-8 UTF-8" >> /mnt/etc/locale.gen
    echo "en_DK.UTF-8 UTF-8" >> /mnt/etc/locale.gen
    ln -sf /usr/share/zoneinfo/Europe/Berlin /mnt/etc/localtime
    arch-chroot /mnt locale-gen
    cat << EOF > /mnt/etc/mkinitcpio.conf
MODULES=()
BINARIES=()
FILES=()
HOOKS=(base consolefont udev autodetect modconf block encrypt-dh filesystems keyboard)
EOF 
    arch-chroot /mnt mkinitcpio -p linu
    arch-chroot /mnt arch-secure-boot initial-setup
}

configure_swap_file() {
    echo -e "\n### Configuring swap file"
    btrfs filesystem mkswapfile --size 4G /mnt/swap/swapfile
    echo "/swap/swapfile none swap defaults 0 0" >> /mnt/etc/fstab
}

create_user() {
    echo -e "\n### Creating user"
    arch-chroot /mnt useradd -m -s /usr/bin/zsh "$user"
    for group in wheel network nzbget video input uucp; do
        arch-chroot /mnt groupadd -rf "$group"
        arch-chroot /mnt gpasswd -a "$user" "$group"
    done
    arch-chroot /mnt chsh -s /usr/bin/zsh
    echo "$user:$password" | arch-chroot /mnt chpasswd
    arch-chroot /mnt passwd -dl root

    echo -e "\n### Setting permissions on the custom repo"
    arch-chroot /mnt chown -R "$user:$user" "/var/cache/pacman/${user}-local/"
}

configure_ssh() {
    echo -e "\n### Configuring SSH"
    install -Dm644 ssh/sshd_config /mnt/etc/ssh/sshd_config
}

configure_security_updates() {
    echo -e "\n### Configuring automated security updates"
    install -Dm644 systemd/system/security-updates.service /mnt/etc/systemd/system/security-updates.service
    install -Dm644 systemd/system/security-updates.timer /mnt/etc/systemd/system/security-updates.timer
    arch-chroot /mnt systemctl enable security-updates.timer
    arch-chroot /mnt systemctl start security-updates.timer
    arch-chroot /mnt systemctl enable fstrim.timer
    arch-chroot /mnt systemctl start fstrim.timer
    arch-chroot /mnt systemctl enable fstrim.timer
    arch-chroot /mnt systemctl start fstrim.timer
}

finalize_installation() {
    echo -e "\n### Reboot now, and after power off remember to unplug the installation USB"
    umount -R /mnt
}

main() {
    check_uefi_mode
    setup_clock
    install_tools
    enable_parallel_downloads
    setup_hidpi
    get_user_input
    select_disks
    setup_fastest_mirrors
    enable_reflector_timer
    setup_firewall
    setup_partitions
    setup_btrfs_subvolumes
    configure_custom_repo
    install_packages
    generate_base_config
    configure_swap_file
    create_user
    configure_ssh
    configure_security_updates
    finalize_installation
}

main "$@"
