#!/bin/bash
# customize_airootfs.sh - runs inside the chroot after all packages install.
#
# The live ISO is the installation source: /usr/local/bin/hacknetos-installer
# copies this root filesystem to the target disk. Keep the live environment as
# close to the installed system as possible, and only strip the parts that are
# wrong for an installed machine (archiso initramfs hook, autologins).

set -uo pipefail

fail() { echo "ERROR: $*" >&2; exit 1; }

echo "=== hacknet-os post-install steps ==="

# Initialize pacman keyring so that package signatures can be verified.
# This must happen before any package operations that require signature verification.
echo "Initializing pacman keyring..."
pacman-key --init
pacman-key --populate archlinux

# The HacknetOS packages are built locally and shipped in the airootfs package
# cache; they are not in the official repositories. Install them offline in one
# transaction. Their dependencies come from packages.x86_64, which is why this
# runs after the normal package installation.
echo "Installing local HacknetOS packages..."
# pacman's CheckSpace cannot determine the root mount point when customize runs
# in a chroot that is not a mountpoint, and aborts with "not enough free disk
# space". Use a throwaway config with the check disabled so the shipped
# /etc/pacman.conf keeps its normal safety net.
cp /etc/pacman.conf /tmp/pacman-offline.conf
sed -i 's/^CheckSpace/#CheckSpace/' /tmp/pacman-offline.conf
pacman -U --noconfirm --overwrite '*' --config /tmp/pacman-offline.conf \
    /var/cache/pacman/pkg/hacknet-keyring-*.pkg.tar.zst \
    /var/cache/pacman/pkg/hacknet-proto-*.pkg.tar.zst \
    /var/cache/pacman/pkg/hacknetd-*.pkg.tar.zst \
    /var/cache/pacman/pkg/hacknetctl-*.pkg.tar.zst \
    /var/cache/pacman/pkg/hacknet-theme-*.pkg.tar.zst \
    /var/cache/pacman/pkg/hacknet-shell-*.pkg.tar.zst \
    /var/cache/pacman/pkg/hacknet-os-*.pkg.tar.zst \
    /var/cache/pacman/pkg/yay-*.pkg.tar.zst \
    || fail "could not install the HacknetOS packages"
rm -f /tmp/pacman-offline.conf

if [ -x /usr/bin/pacman-key ]; then
    /usr/bin/pacman-key --populate hacknetos 2>/dev/null || true
fi

if [[ ! -f /usr/share/quickshell/hacknet/shell.qml ]]; then
    fail "/usr/share/quickshell/hacknet/shell.qml missing"
fi
echo "OK: quickshell shell.qml present"

# The desktop must exist in the live ISO, otherwise the target is empty.
for cmd in hacknet-hyprland hacknetd hacknet-theme hacknetctl quickshell Hyprland foot yay nano hacknet-launcher hacknet-apps; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: $cmd missing from the live ISO (desktop incomplete)" >&2
        exit 1
    fi
    echo "OK: $cmd present"
done

if command -v code >/dev/null 2>&1 || command -v code-oss >/dev/null 2>&1; then
    echo "ERROR: code / code-oss is present on the ISO but should not be" >&2
    exit 1
fi

echo "=== Creating live user ==="
if ! id live &>/dev/null; then
    useradd -m -s /bin/bash -G wheel,video,audio,input,network,storage,power live \
        || echo "WARNING: could not create live user"
fi
passwd -d live >/dev/null 2>&1 || true
echo 'live ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/10-live
chmod 440 /etc/sudoers.d/10-live

echo "=== Hostname ==="
printf 'hacknetos\n' > /etc/hostname
cat > /etc/hosts <<'HOSTS'
127.0.0.1   localhost
::1         localhost
127.0.1.1   hacknetos.localdomain hacknetos
HOSTS

echo "=== Locale / timezone (also stops systemd-firstboot prompting) ==="
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen >/dev/null 2>&1 || echo "WARNING: locale-gen failed"
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf

echo "=== Disabling interactive first-boot setup ==="
# systemd-firstboot otherwise blocks the console asking for a timezone, which
# stops the unattended installer from ever starting.
systemctl mask systemd-firstboot.service >/dev/null 2>&1 || true
systemctl disable systemd-firstboot.service >/dev/null 2>&1 || true

echo "=== Installer helpers must be executable ==="
# A non-executable ExecStart makes systemd fail the unit with 203/EXEC.
chmod 755 /usr/local/bin/hacknetos-* 2>/dev/null || true
for f in /usr/local/bin/hacknetos-*; do
    [[ -x "$f" ]] || { echo "ERROR: $f is not executable" >&2; exit 1; }
    echo "OK: $f executable"
done

echo "=== Installer dependencies ==="
# hacknetos-installer runs from this root filesystem, so every tool it needs
# must be baked into the live image. Trimming the package list has silently
# broken this before ("ERROR: parted is missing").
for tool in parted mkfs.ext4 mkfs.vfat tar arch-chroot genfstab blkid lsblk \
            grub-install grub-mkconfig bootctl efibootmgr useradd chpasswd; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: $tool is missing; the installer cannot run" >&2
        exit 1
    fi
done
echo "OK: all installer dependencies present"

# The Hyprland session falls back to sway on machines without usable EGL.
if [[ ! -f /etc/sway/hacknet.conf ]]; then
    echo "ERROR: /etc/sway/hacknet.conf missing (desktop fallback broken)" >&2
    exit 1
fi
echo "OK: sway fallback config present"

echo "=== Theme ==="
mkdir -p /var/lib/hacknet/theme
hacknet-theme apply blue >/dev/null 2>&1 || echo "WARNING: could not apply theme"

# Install the hacknet theme preset so the HACKNET theme button works.
mkdir -p /usr/share/hacknet/themes
cp /usr/share/hacknetos/theme/presets/hacknet.toml /usr/share/hacknet/themes/hacknet.toml 2>/dev/null || true

# Admin-configurable default theme: /etc/hacknetos/theme.cfg holds one theme id.
mkdir -p /etc/hacknetos
printf 'blue\n' > /etc/hacknetos/theme.cfg

# mpv config: avoid Vulkan (VK_ERROR_INITIALIZATION_FAILED) and the x11_common.c
# assertion abort that follows when gpu-next falls back to indirect GL rendering.
# Prefer DRM/Wayland/OpenGL paths; Vulkan is excluded via gpu-api.
mkdir -p /etc/skel/.config/mpv
cat > /etc/skel/.config/mpv/mpv.conf <<'MPVCONF'
# HacknetOS mpv configuration
# Avoid Vulkan: gpu-next on Vulkan crashes on this hardware stack.
gpu-api=drm,wayland,x11
vo=gpu-next,drm,kwayland,x11
hwdec=auto-safe
scale=ewa_lanczossharp
cscale=mitchell
dscale=linear
audio-display=no
term-osd-bar=no
MPVCONF

# Electron apps (VSCode, etc.) run native Wayland, and GTK apps must route
# Open/Save through the XDG desktop portal. Without GTK_USE_PORTAL the file
# chooser is an in-process dialog that never maps on this compositor.
mkdir -p /etc/environment.d
cat > /etc/environment.d/10-hacknet-desktop.conf <<'ENVCONF'
ELECTRON_OZONE_PLATFORM_HINT=wayland
GTK_USE_PORTAL=1
XDG_CURRENT_DESKTOP=HacknetOS
ENVCONF
grep -q ELECTRON_OZONE_PLATFORM_HINT /etc/environment 2>/dev/null || {
    printf 'ELECTRON_OZONE_PLATFORM_HINT=wayland\n' >> /etc/environment
    printf 'GTK_USE_PORTAL=1\n' >> /etc/environment
    printf 'XDG_CURRENT_DESKTOP=HacknetOS\n' >> /etc/environment
}
sed -i 's/ELECTRON_OZONE_PLATFORM_HINT=auto/ELECTRON_OZONE_PLATFORM_HINT=wayland/' /etc/environment 2>/dev/null || true

# Portal config: use the GTK backend for file choosers (works under sway and
# Hyprland alike).
mkdir -p /etc/xdg/xdg-desktop-portal
cat > /etc/xdg/xdg-desktop-portal/portals.conf <<'PORTALCONF'
[preferred]
default=gtk
org.freedesktop.impl.portal.FileChooser=gtk
PORTALCONF

# Configure Electron flags to always use Wayland native ozone platform
mkdir -p /etc/skel/.config
cat > /etc/skel/.config/electron-flags.conf <<'ELECTRONFLAGS'
--ozone-platform=wayland
--enable-features=WaylandWindowDecorations
ELECTRONFLAGS
cp /etc/skel/.config/electron-flags.conf /etc/skel/.config/electron42-flags.conf

# Clean up any leftover code wrappers or desktop files
rm -f /usr/local/bin/code /usr/local/bin/code-oss /usr/share/applications/code.desktop

# Install nano.desktop and register default MIME associations
mkdir -p /usr/share/applications /etc/xdg
cat > /usr/share/applications/nano.desktop <<'NANODESKTOP'
[Desktop Entry]
Name=Nano
Comment=Terminal Text Editor
GenericName=Text Editor
Exec=foot nano %F
Icon=text-editor
Type=Application
Terminal=false
StartupNotify=false
Categories=Utility;TextEditor;
MimeType=text/plain;text/markdown;application/json;application/xml;text/x-shellscript;text/x-python;text/x-c;text/x-c++;text/x-rust;text/javascript;text/x-lua;text/x-toml;text/x-yaml;application/x-yaml;
Keywords=nano;editor;text;
NANODESKTOP

cat > /etc/xdg/mimeapps.list <<'MIMEAPPS'
[Default Applications]
text/plain=nano.desktop;
text/markdown=nano.desktop;
application/json=nano.desktop;
application/xml=nano.desktop;
text/x-shellscript=nano.desktop;
text/x-python=nano.desktop;
text/x-c=nano.desktop;
text/x-c++=nano.desktop;
text/x-rust=nano.desktop;
text/javascript=nano.desktop;
text/x-lua=nano.desktop;
text/x-toml=nano.desktop;
text/x-yaml=nano.desktop;
application/x-yaml=nano.desktop;

[Added Associations]
text/plain=nano.desktop;
text/markdown=nano.desktop;
application/json=nano.desktop;
application/xml=nano.desktop;
text/x-shellscript=nano.desktop;
text/x-python=nano.desktop;
text/x-c=nano.desktop;
text/x-c++=nano.desktop;
text/x-rust=nano.desktop;
text/javascript=nano.desktop;
text/x-lua=nano.desktop;
text/x-toml=nano.desktop;
text/x-yaml=nano.desktop;
application/x-yaml=nano.desktop;
MIMEAPPS

update-desktop-database 2>/dev/null || true

# Copy configs to any existing user accounts in /home
for userdir in /home/*; do
    if [[ -d "$userdir" ]]; then
        mkdir -p "$userdir/.config"
        rm -f "$userdir/.config/code-flags.conf"
        cp -f /etc/skel/.config/electron-flags.conf "$userdir/.config/" 2>/dev/null || true
        cp -f /etc/skel/.config/electron42-flags.conf "$userdir/.config/" 2>/dev/null || true
        chown -R "$(basename "$userdir"):" "$userdir/.config" 2>/dev/null || true
    fi
done

echo "=== Enabling services ==="
for unit in NetworkManager.service systemd-resolved.service fstrim.timer reflector.timer; do
    systemctl enable "$unit" >/dev/null 2>&1 || echo "WARNING: could not enable $unit"
done
systemctl enable hacknetos-autoinstall.service >/dev/null 2>&1 || true

# Live ISO is text-only: no display manager on the medium. The installed system
# gets its login screen from the installer.
systemctl disable greetd.service >/dev/null 2>&1 || true
systemctl disable getty@tty1.service >/dev/null 2>&1 || true

echo "=== greetd config for installed systems ==="
if ! id -u greeter >/dev/null 2>&1; then
    useradd -r -M -d /var/lib/greetd -s /usr/bin/nologin -G video,input greeter 2>/dev/null || true
else
    usermod -aG video,input greeter 2>/dev/null || true
    usermod -s /usr/bin/nologin greeter 2>/dev/null || true
fi
mkdir -p /var/lib/greetd
chown -R greeter:greeter /var/lib/greetd 2>/dev/null || true

mkdir -p /etc/greetd
cat > /etc/greetd/config.toml <<'GREET'
[terminal]
vt = 1

[general]
source_profile = false

[default_session]
command = "/usr/bin/hacknet-greeter"
user = "greeter"
GREET

echo "=== Live autologin on tty1 and ttyS0 ==="
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<'AUTO'
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin live --noclear %I $TERM
AUTO
mkdir -p /etc/systemd/system/serial-getty@ttyS0.service.d
cp /etc/systemd/system/getty@tty1.service.d/autologin.conf \
   /etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf

echo "=== Live shell starts the installer ==="
cat > /home/live/.bash_profile <<'PROFILE'
# HacknetOS live medium: log in and the installer starts.
# Skipped for unattended installs (hacknetos.autoinstall on the kernel cmdline).
if [ -z "${HACKNET_INSTALLER_STARTED:-}" ] \
   && ! grep -q 'hacknetos\.autoinstall' /proc/cmdline 2>/dev/null; then
    export HACKNET_INSTALLER_STARTED=1
    exec sudo /usr/local/bin/hacknetos-installer
fi

# Unattended install or an aborted installer: leave a usable shell.
[ -f /etc/bash.bashrc ] && . /etc/bash.bashrc
PROFILE
chown live:live /home/live/.bash_profile
chmod 644 /home/live/.bash_profile

# A bashrc so the escape hatch looks sane.
cat > /home/live/.bashrc <<'RC'
alias ls='ls --color=auto'
export PS1='\u@\h \w \$ '
RC
chown live:live /home/live/.bashrc

echo "=== Regenerating initramfs with the archiso hook ==="
dev_repair() {
    if [[ ! -c /dev/null ]]; then rm -f /dev/null; mknod -m 666 /dev/null c 1 3; fi
    [[ -c /dev/zero    ]] || mknod -m 666 /dev/zero    c 1 5
    [[ -c /dev/full    ]] || mknod -m 666 /dev/full    c 1 7
    [[ -c /dev/random  ]] || mknod -m 666 /dev/random  c 1 8
    [[ -c /dev/urandom ]] || mknod -m 666 /dev/urandom c 1 9
    [[ -c /dev/tty     ]] || mknod -m 666 /dev/tty     c 5 0
    [[ -c /dev/ptmx    ]] || mknod -m 666 /dev/ptmx    c 5 2
    [[ -e /dev/fd     ]] || ln -sf /proc/self/fd   /dev/fd
    [[ -e /dev/stdin  ]] || ln -sf /proc/self/fd/0 /dev/stdin
    [[ -e /dev/stdout ]] || ln -sf /proc/self/fd/1 /dev/stdout
    [[ -e /dev/stderr ]] || ln -sf /proc/self/fd/2 /dev/stderr
    mkdir -p /dev/pts /dev/shm
    chmod 1777 /dev/shm 2>/dev/null || true
}
dev_repair

# The build host's kernel (uname -r) is not necessarily the kernel installed
# in this image, so mkinitcpio's default would look for the wrong module tree
# ("ERROR: '/lib/modules/<host>' is not a valid kernel module directory").
# Target the newest kernel that the image actually contains.
KVER="$(ls -1 /usr/lib/modules 2>/dev/null | sort -V | tail -1)"
[[ -n "${KVER}" ]] || fail "no kernel module tree found in /usr/lib/modules"
echo "Building initramfs for kernel ${KVER}"
rm -f /boot/initramfs-linux.img
if ! mkinitcpio -k "${KVER}" -g /boot/initramfs-linux.img -c /etc/mkinitcpio.conf; then
    fail "mkinitcpio failed - refusing to build an unbootable ISO"
fi
# The ISO boot loader loads /arch/boot/x86_64/vmlinuz-linux; make sure a
# matching kernel image exists for the initramfs we just built.
if [[ ! -f /boot/vmlinuz-linux ]]; then
    if [[ -f "/usr/lib/modules/${KVER}/vmlinuz" ]]; then
        cp "/usr/lib/modules/${KVER}/vmlinuz" /boot/vmlinuz-linux
    fi
fi

validate_initramfs() {
    local img="$1" listing n
    if [[ ! -s "$img" ]]; then
        echo "  invalid: $img is missing or empty" >&2
        return 1
    fi
    if ! listing=$(lsinitcpio -l "$img" 2>/dev/null); then
        echo "  invalid: cannot list $img" >&2
        return 1
    fi
    if ! grep -qx 'init' <<<"$listing"; then
        echo "  invalid: $img has no /init" >&2
        return 1
    fi
    if ! grep -qx 'hooks/archiso' <<<"$listing"; then
        echo "  invalid: $img has no hooks/archiso (live medium will not be found)" >&2
        return 1
    fi
    n=$(wc -l <<<"$listing")
    if (( n < 200 )); then
        echo "  invalid: $img is implausibly small ($n entries)" >&2
        return 1
    fi
    echo "  OK: $img valid ($n entries, init + hooks/archiso present)"
    return 0
}
validate_initramfs /boot/initramfs-linux.img || fail "initramfs validation failed"

echo "=== customize_airootfs.sh complete ==="
