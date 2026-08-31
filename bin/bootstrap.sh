#!/usr/bin/env bash
set -euo pipefail

cfg=/persist/config.env
sec=/persist/secrets.env

dump_failure() {
  local code=$?
  local boot_mnt=""
  for m in /boot/firmware /boot; do
    if [[ -d "$m" ]]; then boot_mnt="$m"; break; fi
  done
  if [[ -n "$boot_mnt" ]]; then
    mount -o remount,rw "$boot_mnt" 2>/dev/null || true
    {
      echo "=== APPLIANCE BOOTSTRAP FAILURE (exit code $code) ==="
      echo "Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || date)"
      echo "Uptime: $(uptime 2>/dev/null || true)"
      echo ""
      echo "=== Persistent Config Status ==="
      ls -la /persist 2>/dev/null || true
      echo ""
      echo "=== Network Interfaces & Addresses ==="
      ip addr show 2>/dev/null || ifconfig -a 2>/dev/null || true
      echo ""
      echo "=== Block Devices ==="
      lsblk -f 2>/dev/null || true
      echo ""
      echo "=== Mounts ==="
      mount 2>/dev/null || true
      echo ""
      echo "=== Kernel Messages ==="
      dmesg | tail -n 120 2>/dev/null || true
      echo "=== END OF DUMP ==="
    } > "$boot_mnt/LAST_BOOT_FAILURE.txt"
    sync
    mount -o remount,ro "$boot_mnt" 2>/dev/null || true
  fi
  exit "$code"
}
trap dump_failure ERR

[[ -s "$cfg" && -s "$sec" ]] || { echo "Missing persistent configuration" >&2; exit 1; }
chmod 0600 "$cfg" "$sec"

grep -q '^HOSTNAME=' "$cfg"
grep -q '^WEBDAV_DOMAIN=' "$cfg"
grep -Eq '^ADMIN_SSH_PUBLIC_KEY="?ssh-' "$cfg"
grep -q '^TAILSCALE_AUTH_KEY=' "$sec"
grep -q '^CLOUDFLARE_API_TOKEN=' "$sec"
grep -q '^ADMIN_PAM_PASSWORD_HASH=' "$sec"

if grep -q 'REPLACE_ME' "$cfg" "$sec"; then
  echo "bootstrap files still contain REPLACE_ME placeholders" >&2
  exit 1
fi

. "$cfg"
. "$sec"

user="${ADMIN_USERNAME:-admin}"

install -d -m 0700 /persist/{ssh,"ssh/$user",tailscale,acme,cloudflare,update,auth}
[[ -d /var/empty ]] || { mkdir -p /var/empty && chmod 0555 /var/empty; }

# Provision Unix user if different from static admin
if ! id -u "$user" >/dev/null 2>&1; then
  useradd -m -s /run/current-system/sw/bin/bash -G wheel,shadow -u 1000 "$user" 2>/dev/null || true
fi

if [[ -n "${ADMIN_SSH_PUBLIC_KEY:-}" ]]; then
  install -d -m 0700 "/persist/ssh/$user"
  printf '%s\n' "$ADMIN_SSH_PUBLIC_KEY" > "/persist/ssh/$user/authorized_keys"
  chmod 0600 "/persist/ssh/$user/authorized_keys"
  chown -R "$user:users" "/persist/ssh/$user" 2>/dev/null || true
fi

if [[ -n "${ADMIN_PAM_PASSWORD_HASH:-}" ]]; then
  install -d -m 0700 /persist/auth
  hash="${ADMIN_PAM_PASSWORD_HASH#\'}"
  hash="${hash%\'}"
  hash="${hash#\"}"
  hash="${hash%\"}"
  printf 'root:!:19700:0:99999:7:::\n%s:%s:19700:0:99999:7:::\n' "$user" "$hash" > /persist/auth/shadow
  chmod 0600 /persist/auth/shadow
  if [[ -d /run ]]; then
    cp -f /persist/auth/shadow /run/shadow 2>/dev/null || true
    chmod 0644 /run/shadow 2>/dev/null || true
    chown root:shadow /run/shadow 2>/dev/null || true
  fi
fi

if [[ ! -f /persist/ssh/ssh_host_ed25519_key ]]; then
  ssh-keygen -t ed25519 -N "" -f /persist/ssh/ssh_host_ed25519_key
fi
if [[ ! -f /persist/ssh/ssh_host_rsa_key ]]; then
  ssh-keygen -t rsa -b 3072 -N "" -f /persist/ssh/ssh_host_rsa_key
fi
chmod 0600 /persist/ssh/ssh_host_*_key

if [[ -n "${WEBDAV_DOMAIN:-}" && ( ! -s "/persist/acme/$WEBDAV_DOMAIN/fullchain.pem" || ! -s "/persist/acme/$WEBDAV_DOMAIN/key.pem" ) ]]; then
  install -d -m 0700 "/persist/acme/$WEBDAV_DOMAIN"
  openssl req -x509 -newkey rsa:2048 -keyout "/persist/acme/$WEBDAV_DOMAIN/key.pem" -out "/persist/acme/$WEBDAV_DOMAIN/fullchain.pem" -days 365 -nodes -subj "/CN=$WEBDAV_DOMAIN"
  chmod 0600 "/persist/acme/$WEBDAV_DOMAIN/key.pem"
  chmod 0644 "/persist/acme/$WEBDAV_DOMAIN/fullchain.pem"
fi

if [[ -d "/home/$user" ]]; then
  install -d -m 0700 -o "$user" -g users "/home/$user" "/home/$user/.ssh" 2>/dev/null || true
  if [[ -s "/persist/ssh/$user/authorized_keys" ]]; then
    cp -f "/persist/ssh/$user/authorized_keys" "/home/$user/.ssh/authorized_keys" 2>/dev/null || true
    chmod 0600 "/home/$user/.ssh/authorized_keys" 2>/dev/null || true
    chown -R "$user:users" "/home/$user" 2>/dev/null || true
  fi
fi

trap - ERR

