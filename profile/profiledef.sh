#!/bin/bash
# HacknetOS archiso profile definition

iso_name="hacknetos"
iso_label="HACKNETOS_$(date +%Y%m)"
iso_publisher="HacknetOS <https://github.com/hacknetos/hacknetos>"
iso_application="HacknetOS Live/Install ISO"
iso_version="${HACKNET_ISO_VERSION:-0.1.0-$(date +%Y%m%d)}"
install_dir="arch"
bootmodes=('bios.syslinux' 'uefi.systemd-boot')
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=(-comp zstd -Xcompression-level 12)
file_permissions=(
    ["/etc/shadow"]="0:0:400"
    ["/etc/gshadow"]="0:0:400"
    ["/root"]="0:0:750"
    ["/usr/local/bin/hacknetos-autoinstall"]="0:0:755"
    ["/usr/local/bin/hacknetos-installer"]="0:0:755"
    ["/usr/local/bin/hacknetos-setup-live"]="0:0:755"
    ["/usr/local/bin/hacknetos-create-live-user"]="0:0:755"
)