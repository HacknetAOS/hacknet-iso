# hacknet-iso

[![ISO CI](https://github.com/HacknetAOS/hacknet-iso/actions/workflows/build-iso.yml/badge.svg)](https://github.com/HacknetAOS/hacknet-iso/actions/workflows/build-iso.yml)

`archiso` profile and build pipeline for HacknetOS bootable installation media. Produces a hybrid UEFI + BIOS ISO image containing the offline/online disk installer (`hacknetos-installer`) and the complete HacknetOS desktop stack.

## Building Locally

### Prerequisites
- Arch Linux host or privileged container
- Installed packages: `archiso`, `squashfs-tools`, `libisoburn` (`xorriso`), `dosfstools`, `mtools`

### Build
```bash
sudo ./build-iso.sh [output_dir]
```

`build-iso.sh` automatically stages packages from `../repo/x86_64/` (or `../packages/pkg-out/`, or the bundled `profile/airootfs/var/cache/pacman/pkg/` cache), builds the image with `mkarchiso`, and verifies both the initramfs (`hooks/archiso` + `/init`) and bootloader `archisolabel` entries before finishing.

## License

GPL-3.0-or-later
