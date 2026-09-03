#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# PERSISTENT STATE BIND MOUNTS
# All persistent state lives in /persist (separate ext4 partition on mmcblk0p2).
# This function bind-mounts /persist/* directories to their standard locations.
# Runs early in boot (After=local-fs.target, Before=services) so services
# see the persistent state at standard paths.
# During remote deploy, rsync with --one-file-system skips these bind mounts
# automatically, preserving SSH keys, Tailscale state, ACME certs.
# User homes are intentionally NOT persisted - users should write to data disk.
# ==============================================================================

setup_persist_bind_mounts() {
    local persist_dirs=(
        "ssh:/etc/ssh"
        "tailscale:/var/lib/tailscale"
        "acme:/etc/lego"
        "auth:/etc/apache2/auth"
        "state:/var/lib/appliance"
    )

    for entry in "${persist_dirs[@]}"; do
        local src="${entry%%:*}"
        local dst="${entry##*:}"
        local src_path="/persist/$src"

        mkdir -p "$src_path"
        mkdir -p "$(dirname "$dst")"

        # Bind mount if not already mounted
        if ! mountpoint -q "$dst" 2>/dev/null; then
            mount --bind "$src_path" "$dst"
            echo "persist-bind: mounted $src_path -> $dst"
        fi
    done
}

# ==============================================================================
# MAIN BOOTSTRAP LOGIC (runs after bind mounts are established)
# ==============================================================================

setup_persist_bind_mounts

# Sync configuration from boot partition if provided
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

user="${ADMIN_USERNAME:-admin}"
hash="${ADMIN_PAM_PASSWORD_HASH#\'}"
hash="${hash%\'}"

# Ensure user exists in /etc/passwd if cloud-init didn't add it
# User home is on tmpfs overlay (non-persistent) - users write to data disk
if ! id "$user" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -p "$hash" "$user" 2>/dev/null || true
    usermod -aG sudo "$user" 2>/dev/null || true
fi

# Generate htpasswd for WebDAV (writes to /persist/auth via bind mount)
mkdir -p /persist/auth
echo "${user}:${hash}" > /persist/auth/htpasswd
chmod 0600 /persist/auth/htpasswd
chown www-data:www-data /persist/auth/htpasswd 2>/dev/null || true

# Set up SSH authorized keys (writes to user's home on tmpfs overlay)
mkdir -p "/home/$user/.ssh"
echo "$ADMIN_SSH_PUBLIC_KEY" > "/home/$user/.ssh/authorized_keys"
chown -R "$user:$user" "/home/$user/.ssh" 2>/dev/null || true
chmod 0700 "/home/$user/.ssh" 2>/dev/null || true
chmod 0600 "/home/$user/.ssh/authorized_keys" 2>/dev/null || true

# SSH host keys now persist automatically via /persist/ssh bind mount to /etc/ssh
# Generate only if missing
has_keys=false
for k in /etc/ssh/ssh_host_*_key; do
    [[ -s "$k" ]] && { has_keys=true; break; }
done

if ! $has_keys; then
    ssh-keygen -A 2>/dev/null || true
    echo "bootstrap: generated new SSH host keys in /persist/ssh"
fi
chmod 0600 /etc/ssh/ssh_host_*_key 2>/dev/null || true
chmod 0644 /etc/ssh/ssh_host_*_key.pub 2>/dev/null || true