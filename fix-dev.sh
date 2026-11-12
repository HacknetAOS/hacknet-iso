#!/bin/bash
# Repairs a stripped /dev inside this container.
# Deliberately avoids 2>/dev/null redirects until /dev/null is writable.
set -u

# 1. Make null/zero usable first (chicken-and-egg for redirects).
chmod 666 /dev/null 2>&1
[ -e /dev/zero ] || mknod -m 666 /dev/zero c 1 5
chmod 666 /dev/zero 2>&1

# 2. Core character devices
[ -e /dev/full ]    || mknod -m 666 /dev/full c 1 7
[ -e /dev/random ]  || mknod -m 666 /dev/random c 1 8
[ -e /dev/urandom ] || mknod -m 666 /dev/urandom c 1 9
[ -e /dev/tty ]     || mknod -m 666 /dev/tty c 5 0
[ -e /dev/console ] || mknod -m 600 /dev/console c 5 1
[ -e /dev/ptmx ]    || mknod -m 666 /dev/ptmx c 5 2

# 3. Standard symlinks
[ -e /dev/fd ]     || ln -sf /proc/self/fd /dev/fd
[ -e /dev/stdin ]  || ln -sf /proc/self/fd/0 /dev/stdin
[ -e /dev/stdout ] || ln -sf /proc/self/fd/1 /dev/stdout
[ -e /dev/stderr ] || ln -sf /proc/self/fd/2 /dev/stderr

# 4. Directories needed by pty and shared memory users
mkdir -p /dev/pts /dev/shm
chmod 1777 /dev/shm
mount -t devpts devpts /dev/pts 2>/dev/null || true
mount -t tmpfs -o mode=1777,nosuid,nodev tmpfs /dev/shm 2>/dev/null || true

# 5. Common block/loop nodes (harmless if unused, helps losetup in chroots)
for i in $(seq 0 15); do
    [ -e "/dev/loop$i" ] || mknod -m 660 "/dev/loop$i" b 7 "$i"
done
[ -e /dev/loop-control ] || mknod -m 660 /dev/loop-control c 10 237

echo "=== /dev after repair ==="
ls -la /dev/ | head -40
echo "=== writability checks ==="
echo test > /dev/null && echo "/dev/null: writable"
head -c 16 /dev/urandom | od -An -tx1 && echo "/dev/urandom: readable"
echo test > /dev/tty && echo "/dev/tty: writable" || echo "/dev/tty: not writable (no controlling tty, ok)"
