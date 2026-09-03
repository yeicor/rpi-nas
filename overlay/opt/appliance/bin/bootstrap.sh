#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# PERSISTENT STATE ARCHITECTURE
#
# Hardware: /dev/mmcblk0p2 (ext4) is the dedicated persistent partition.
#
# Problem: overlayroot creates an overlay at /persist (ext4 RO + tmpfs RW).
#          Writes to /persist go to tmpfs and are LOST on reboot.
#
# Solution: Mount the ext4 RW directly, replacing the overlay at /persist.
#           All code referencing /persist now writes to real ext4 storage.
#
# What lives on /persist (minimal SD card writes):
#   ssh/           - SSH host keys only (symlinked to /etc/ssh/)
#   tailscale/     - Tailscale auth state (bind-mounted to /var/lib/tailscale)
#   acme/          - Let's Encrypt certs (bind-mounted to /etc/lego)
#   config.env     - Copied from /boot/firmware on each boot
#   secrets.env    - Copied from /boot/firmware on each boot
#
# What does NOT live on /persist:
#   /home          - User homes on tmpfs overlay; write to data disk instead
#   /etc/ssh/*     - Only host keys persisted via symlinks; sshd_config etc
#                    come from the image (so security updates apply)
#   WebDAV auth    - PAM-based, no htpasswd persistence needed
# ==============================================================================

# Mount the ext4 partition RW and replace the overlay at /persist
# Overlayroot mounts /dev/mmcblk0p2 RO (fstab 'ro') and stacks a tmpfs overlay
# on top of /persist. Writes to /persist through that overlay go to tmpfs and
# are LOST on reboot. A fresh 'mount ... -o rw' also reuses the already-present
# RO superblock. So we must (a) remount RW and (b) REMOVE the overlay mount so
# the real ext4 bind mount at /persist is what actually receives writes.
mount_persist_ext4() {
    mkdir -p /persist-ext4
    if ! mountpoint -q /persist-ext4 2>/dev/null; then
        mount /dev/mmcblk0p2 /persist-ext4 -o rw,noatime 2>/dev/null \
            || mount /dev/mmcblk0p2 /persist-ext4
        echo "bootstrap: mounted /dev/mmcblk0p2 -> /persist-ext4"
    fi
    # Override overlayroot's accidental RO flag (device already mounted RO)
    mount -o remount,rw /persist-ext4 2>/dev/null || true
    if findmnt -no OPTIONS /persist-ext4 | grep -q '^ro'; then
        echo "bootstrap: WARNING /persist-ext4 is still read-only" >&2
    fi

    # Drop the tmpfs overlay that overlayroot stacked at /persist, otherwise
    # writes to /persist land in tmpfs and are lost on reboot. Use lazy umount
    # to avoid failing if a process briefly holds a file open.
    if mountpoint -q /persist && findmnt -n -o FSTYPE /persist | grep -q overlay; then
        umount -l /persist 2>/dev/null || true
        echo "bootstrap: removed overlayroot tmpfs overlay at /persist"
    fi

    mount --bind /persist-ext4 /persist
    echo "bootstrap: bound /persist-ext4 -> /persist (replaced overlay)"
}

# Set up bind mounts from /persist to standard runtime paths.
# These persist across reboots because /persist is now real ext4.
# Deploy rsync with -x (--one-file-system) skips these mount points.
setup_persist_bind_mounts() {
    local persist_dirs=(
        "tailscale:/var/lib/tailscale"
        "acme:/etc/lego"
    )

    for entry in "${persist_dirs[@]}"; do
        local src="${entry%%:*}"
        local dst="${entry##*:}"
        local src_path="/persist/$src"

        # Destination (/var/lib/tailscale, /etc/lego) may not exist yet at boot;
        # create it so 'mount --bind' has a mountpoint to attach to.
        mkdir -p "$src_path" "$dst"

        if ! mountpoint -q "$dst" 2>/dev/null; then
            mount --bind "$src_path" "$dst"
            echo "persist-bind: $src_path -> $dst"
        fi
    done
}

# ==============================================================================
# BOOT SEQUENCE
#
# Order matters:
#   1. Mount ext4 over /persist overlay (makes /persist real storage)
#   2. Sync config files from /boot/firmware
#   3. Set up user
#   4. Seed persistent state from image (BEFORE bind mounts cover source dirs)
#   5. Set up bind mounts and symlinks (persistent state now at standard paths)
# ==============================================================================

# Step 1: Mount ext4 directly over the overlay at /persist
mount_persist_ext4

# Step 2: Sync configuration from boot partition
boot_mnt="/boot/firmware"
if [[ -f "$boot_mnt/config.env" ]]; then
    cp "$boot_mnt/config.env" /persist/config.env
    chmod 0600 /persist/config.env
fi
if [[ -f "$boot_mnt/secrets.env" ]]; then
    cp "$boot_mnt/secrets.env" /persist/secrets.env
    chmod 0600 /persist/secrets.env
fi

[[ -f /persist/config.env && -f /persist/secrets.env ]] || { echo "Missing configuration!"; exit 1; }

. /persist/config.env
. /persist/secrets.env

# Apply configured hostname so config.env changes take effect without re-flash.
#
# /etc/hostname lives on the read-only overlay root and can't be written
# directly; a transient hostname is ignored when a static one is already set.
# So we persist the hostname on /persist and bind-mount it over /etc/hostname
# (writable), then set the static hostname so it survives reboots and deploys.
apply_hostname() {
    local wanted="${HOSTNAME:-}"
    [[ -n "$wanted" ]] || return 0

    if [[ ! -f /persist/hostname ]] || [[ "$(cat /persist/hostname 2>/dev/null)" != "$wanted" ]]; then
        printf '%s\n' "$wanted" > /persist/hostname
        chmod 0644 /persist/hostname
    fi
    if ! mountpoint -q /etc/hostname 2>/dev/null; then
        mount --bind /persist/hostname /etc/hostname
    fi
    if [[ "$(hostname)" != "$wanted" ]]; then
        hostnamectl set-hostname "$wanted" 2>/dev/null || true
    fi
    echo "bootstrap: hostname is $(hostname) (persisted via /persist/hostname)"
}
apply_hostname

user="${ADMIN_USERNAME:-admin}"
hash="${ADMIN_PAM_PASSWORD_HASH#\'}"
hash="${hash%\'}"

# Step 3: Ensure user exists (home is on tmpfs overlay, non-persistent)
if ! id "$user" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -p "$hash" "$user" 2>/dev/null || true
    usermod -aG sudo "$user" 2>/dev/null || true
fi

# Set up SSH authorized keys (on tmpfs home; regenerated each boot from config)
mkdir -p "/home/$user/.ssh"
echo "$ADMIN_SSH_PUBLIC_KEY" > "/home/$user/.ssh/authorized_keys"
chown -R "$user:$user" "/home/$user/.ssh" 2>/dev/null || true
chmod 0700 "/home/$user/.ssh" 2>/dev/null || true
chmod 0600 "/home/$user/.ssh/authorized_keys" 2>/dev/null || true

# Step 4: Seed SSH host keys to /persist BEFORE any bind mounts or symlinks.
# On first boot: /persist/ssh is empty, image has build-generated keys.
# On subsequent boots: /persist/ssh already has keys (from ext4).
# After deploy: /persist/ssh retains old keys (rsync -x skips bind mounts).
has_persist_keys=false
for k in /persist/ssh/ssh_host_*_key; do
    [[ -s "$k" ]] && { has_persist_keys=true; break; }
done

if ! $has_persist_keys; then
    mkdir -p /persist/ssh
    if ls /etc/ssh/ssh_host_*_key 1>/dev/null 2>&1; then
        cp -a /etc/ssh/ssh_host_* /persist/ssh/
        echo "bootstrap: seeded SSH host keys to /persist/ssh from build image"
    else
        ssh-keygen -A 2>/dev/null || true
        cp -a /etc/ssh/ssh_host_* /persist/ssh/ 2>/dev/null || true
        echo "bootstrap: generated new SSH host keys"
    fi
    sync
fi

chmod 0600 /persist/ssh/ssh_host_*_key 2>/dev/null || true
chmod 0644 /persist/ssh/ssh_host_*_key.pub 2>/dev/null || true

# Step 5: Symlink host keys from /persist/ssh into /etc/ssh.
# This preserves host keys across reboots and deploys while letting
# sshd_config and other config files come from the current image.
for keyfile in /persist/ssh/ssh_host_*_key /persist/ssh/ssh_host_*_key.pub; do
    [[ -f "$keyfile" ]] || continue
    ln -sf "$keyfile" "/etc/ssh/$(basename "$keyfile")"
done
echo "bootstrap: linked persistent SSH host keys into /etc/ssh"

# Step 6: Set up bind mounts for tailscale state and ACME certs
setup_persist_bind_mounts
