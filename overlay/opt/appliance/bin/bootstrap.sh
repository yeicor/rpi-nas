#!/usr/bin/env bash
set -euo pipefail

mkdir -p /persist/home /persist/state /persist/auth /persist/acme /persist/tailscale /persist/ssh

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
if ! id "$user" >/dev/null 2>&1; then
  mount -o remount,rw / || true
  useradd -m -s /bin/bash -p "$hash" "$user" 2>/dev/null || true
  usermod -aG sudo "$user" 2>/dev/null || true
  mount -o remount,ro / || true
fi

# Generate htpasswd for WebDAV
echo "${user}:${hash}" > /persist/auth/htpasswd
chmod 0600 /persist/auth/htpasswd
chown www-data:www-data /persist/auth/htpasswd 2>/dev/null || true

# Set up SSH authorized keys with correct user ownership
mkdir -p "/persist/home/$user/.ssh"
echo "$ADMIN_SSH_PUBLIC_KEY" > "/persist/home/$user/.ssh/authorized_keys"
chown -R "$user:$user" "/persist/home/$user" 2>/dev/null || true
chmod 0700 "/persist/home/$user/.ssh" 2>/dev/null || true
chmod 0600 "/persist/home/$user/.ssh/authorized_keys" 2>/dev/null || true

# Also ensure /home/$user/.ssh exists and has correct ownership
mkdir -p "/home/$user/.ssh" 2>/dev/null || true
echo "$ADMIN_SSH_PUBLIC_KEY" > "/home/$user/.ssh/authorized_keys" 2>/dev/null || true
chown -R "$user:$user" "/home/$user" 2>/dev/null || true
chmod 0700 "/home/$user/.ssh" 2>/dev/null || true
chmod 0600 "/home/$user/.ssh/authorized_keys" 2>/dev/null || true
