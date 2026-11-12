#!/bin/bash
# HacknetOS ISO build script
# Usage: sudo ./build-iso.sh [output_dir]
#
# The initramfs is generated inside customize_airootfs.sh (in the chroot),
# so it is already correct when mkarchiso packs the ISO. No post-processing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_DIR="${SCRIPT_DIR}/profile"
OUTPUT_DIR="${1:-${SCRIPT_DIR}/out}"
WORK_DIR="${OUTPUT_DIR}/work"

# Find package directory: check PKG_DIR env, sibling repo/x86_64, or sibling packages/pkg-out
PKG_DIR="${PKG_DIR:-}"
for cand in "${PKG_DIR}" "${SCRIPT_DIR}/../repo/x86_64" "${SCRIPT_DIR}/../packages/pkg-out"; do
    if [ -n "$cand" ] && [ -d "$cand" ] && compgen -G "$cand/hacknet-os*.pkg.tar.zst" >/dev/null; then
        PKG_DIR="$cand"
        break
    fi
done

if [ -z "$PKG_DIR" ]; then
    PKG_DIR="${SCRIPT_DIR}/profile/airootfs/var/cache/pacman/pkg"
fi

if [[ ${EUID} -ne 0 ]]; then
    echo "This script must be run as root (for mkarchiso)" >&2
    exit 1
fi

OUTPUT_DIR=$(realpath -m "${OUTPUT_DIR}")
WORK_DIR="${OUTPUT_DIR}/work"
PROFILE_DIR=$(realpath "${PROFILE_DIR}")
PKG_DIR=$(realpath "${PKG_DIR}")

# /tmp in some build hosts is a small tmpfs with a user quota; writing multi-GB
# package downloads there fails with "Disk quota exceeded" and yields 0-byte
# files. Keep all scratch data on the same filesystem as the output.
export TMPDIR="${OUTPUT_DIR}/.tmp"
mkdir -p "${TMPDIR}"

echo "=== HacknetOS ISO Builder ==="
echo "Profile:  ${PROFILE_DIR}"
echo "Output:   ${OUTPUT_DIR}"
echo "Work:     ${WORK_DIR}"
echo "Packages: ${PKG_DIR}"

# /dev/fd is needed by bash process substitution in some build steps
[[ -e /dev/fd ]] || ln -sf /proc/self/fd /dev/fd

echo "=== Pre-build /dev check ==="
# Do NOT unmount /dev: in a container /dev is often the only devtmpfs and
# unmounting it leaves the host with a stripped /dev, which then corrupts the
# initramfs built inside the chroot. Only unmount leftovers under WORK_DIR.
if [[ -d "${WORK_DIR}" ]]; then
    while read -r mp; do
        umount -l "${mp}" 2>/dev/null || umount -f "${mp}" 2>/dev/null || true
    done < <(awk -v d="${WORK_DIR}" '$2 ~ "^"d {print $2}' /proc/mounts | sort -r)
fi
# Repair essential device nodes if a previous build damaged them.
if [[ -x "${SCRIPT_DIR}/fix-dev.sh" ]]; then
    bash "${SCRIPT_DIR}/fix-dev.sh" >/dev/null 2>&1 || true
fi
if [[ ! -c /dev/null ]] || [[ ! -c /dev/urandom ]]; then
    echo "ERROR: /dev is missing essential character devices (null/urandom)." >&2
    echo "       Run: sudo bash ${SCRIPT_DIR}/fix-dev.sh" >&2
    exit 1
fi
echo "=== /dev check complete ==="

echo "=== Staging packages into host and ISO airootfs pacman cache ==="
mkdir -p /var/cache/pacman/pkg
rm -f "${PKG_DIR}"/*-debug-*.pkg.tar.zst
rm -f /var/cache/pacman/pkg/hacknet*.pkg.tar.zst /var/cache/pacman/pkg/yay*.pkg.tar.zst
cp -f "${PKG_DIR}"/*.pkg.tar.zst /var/cache/pacman/pkg/

ISO_PKG_CACHE="${PROFILE_DIR}/airootfs/var/cache/pacman/pkg"
mkdir -p "${ISO_PKG_CACHE}"
rm -f "${ISO_PKG_CACHE}"/hacknet*.pkg.tar.zst "${ISO_PKG_CACHE}"/yay*.pkg.tar.zst
for pkg in hacknet-keyring hacknet-proto hacknet-theme hacknetd hacknetctl hacknet-shell hacknet-os yay; do
    cp -f "${PKG_DIR}/${pkg}"-[0-9]*.pkg.tar.zst "${ISO_PKG_CACHE}/"
done
ls -lh "${ISO_PKG_CACHE}"/*.pkg.tar.zst

echo "=== Building local repo database ==="
repo-add -q /var/cache/pacman/pkg/hacknetos.db.tar.gz /var/cache/pacman/pkg/*.pkg.tar.zst >/dev/null

echo "=== Writing build pacman.conf ==="
# Always start from a completely clean work tree. Reusing it leaves stale
# generated boot-loader configs behind: an ISO built in a new month then keeps
# the previous month's archisolabel and fails at boot with
#   ERROR: '/dev/disk/by-label/HACKNETOS_YYYYMM' device did not show up
if [[ -d "${WORK_DIR}" ]]; then
    echo "=== Removing previous work tree ==="
    while read -r mp; do
        umount -l "${mp}" 2>/dev/null || umount -f "${mp}" 2>/dev/null || true
    done < <(awk -v d="${WORK_DIR}" '$2 ~ "^"d {print $2}' /proc/mounts | sort -r)
    rm -rf "${WORK_DIR}"
fi

mkdir -p "${WORK_DIR}"
cat > "${WORK_DIR}/pacman.conf" <<'PACMANEOF'
[options]
HoldPkg     = pacman glibc
Architecture = auto
Color
CheckSpace
ParallelDownloads = 5
SigLevel    = Required DatabaseOptional
LocalFileSigLevel = Optional

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[multilib]
Include = /etc/pacman.d/mirrorlist

[hacknetos]
SigLevel = Optional TrustAll
Server = file:///var/cache/pacman/pkg
PACMANEOF

echo "=== Building ISO with mkarchiso ==="
rm -f "${OUTPUT_DIR}"/hacknetos-*.iso
mkarchiso -v \
    -w "${WORK_DIR}" \
    -o "${OUTPUT_DIR}" \
    -C "${WORK_DIR}/pacman.conf" \
    "${PROFILE_DIR}"

ISO_FILE=$(find "${OUTPUT_DIR}" -maxdepth 1 -name 'hacknetos-*.iso' -type f | head -1)
if [[ -z "${ISO_FILE}" ]]; then
    echo "ERROR: no ISO produced" >&2
    exit 1
fi

echo "=== Verifying the ISO's initramfs can find the live medium ==="
# A truncated initramfs (no /init, no hooks/archiso) boots straight into
# "VFS: Unable to mount root fs on unknown-block(0,0)" - a kernel panic.
# Catch that here instead of shipping an unbootable ISO.
VERIFY_IMG="${OUTPUT_DIR}/verify-initramfs.img"
VERIFY_LIST="${OUTPUT_DIR}/verify-initramfs.txt"
CHROOT_ROOT="${WORK_DIR}/x86_64/airootfs"
rm -f "${VERIFY_IMG}" "${VERIFY_LIST}"
xorriso -indev "${ISO_FILE}" -osirrox on \
    -extract /arch/boot/x86_64/initramfs-linux.img "${VERIFY_IMG}" >/dev/null 2>&1 || true
if [[ ! -s "${VERIFY_IMG}" ]]; then
    echo "ERROR: could not extract initramfs from ISO" >&2
    exit 1
fi
cp -f "${VERIFY_IMG}" "${CHROOT_ROOT}/boot/verify-initramfs.img"
if ! arch-chroot "${CHROOT_ROOT}" lsinitcpio -l /boot/verify-initramfs.img \
        > "${VERIFY_LIST}" 2>/dev/null; then
    echo "ERROR: cannot inspect the ISO initramfs" >&2
    exit 1
fi
rm -f "${CHROOT_ROOT}/boot/verify-initramfs.img"
ENTRIES=$(wc -l < "${VERIFY_LIST}")
if ! grep -qx 'init' "${VERIFY_LIST}" \
   || ! grep -qx 'hooks/archiso' "${VERIFY_LIST}" \
   || (( ENTRIES < 200 )); then
    echo "ERROR: ISO initramfs is unbootable (${ENTRIES} entries; init/hooks/archiso missing)" >&2
    exit 1
fi
echo "OK: ISO initramfs is bootable (${ENTRIES} entries, init + hooks/archiso present)"

echo "=== Verifying boot entries reference the real volume label ==="
VOL=$(xorriso -indev "${ISO_FILE}" -report_el_torito 2>&1 \
      | sed -n "s/^Volume id *: '\(.*\)'/\1/p" | head -1)
if [[ -z "${VOL}" ]]; then
    echo "ERROR: cannot read the ISO volume id" >&2
    exit 1
fi
CHK_DIR="${OUTPUT_DIR}/labelcheck"
rm -rf "${CHK_DIR}"; mkdir -p "${CHK_DIR}"
xorriso -indev "${ISO_FILE}" -osirrox on \
    -extract /boot/syslinux/syslinux.cfg "${CHK_DIR}/syslinux.cfg" >/dev/null 2>&1 || true
xorriso -indev "${ISO_FILE}" -osirrox on \
    -extract /loader/entries/hacknetos.conf "${CHK_DIR}/loader.conf" >/dev/null 2>&1 || true
LABEL_BAD=0
for f in "${CHK_DIR}"/*; do
    [[ -f "$f" ]] || continue
    if ! grep -q "archisolabel=${VOL}\( \|$\)" "$f"; then
        echo "ERROR: $(basename "$f") does not request archisolabel=${VOL}" >&2
        grep -h archisolabel "$f" >&2 || true
        LABEL_BAD=1
    fi
done
if (( LABEL_BAD )); then
    echo "ERROR: the ISO would not find its own live medium at boot" >&2
    exit 1
fi
echo "OK: boot entries use archisolabel=${VOL}"

echo "=== ISO build complete ==="
ls -lh "${ISO_FILE}"

echo "=== Cleaning up build mounts ==="
# Never unmount /dev here (see pre-build note). Only release work-dir mounts.
if [[ -d "${WORK_DIR}" ]]; then
    while read -r mp; do
        umount -l "${mp}" 2>/dev/null || umount -f "${mp}" 2>/dev/null || true
    done < <(awk -v d="${WORK_DIR}" '$2 ~ "^"d {print $2}' /proc/mounts | sort -r)
fi
if [[ -x "${SCRIPT_DIR}/fix-dev.sh" ]]; then
    bash "${SCRIPT_DIR}/fix-dev.sh" >/dev/null 2>&1 || true
fi
echo "=== Build cleanup complete ==="
