#!/usr/bin/env bash
set -euo pipefail
. /persist/config.env

device="${DATA_DEVICE:-/dev/sda}"
user="${ADMIN_USERNAME:-admin}"
mountpoint=/run/webdav-data
install -d -m 0755 "$mountpoint"

for _ in $(seq 1 24); do
  [[ -b "$device" ]] && break
  sleep 5
done
[[ -b "$device" ]] || { echo "data device $device is absent; WebDAV disabled" >&2; exit 1; }

if [[ "$(lsblk -dnro TYPE "$device")" == disk && -z "$(lsblk -dnro FSTYPE "$device")" ]]; then
  child="$(lsblk -nrpo NAME,FSTYPE,TYPE "$device" | awk '$2 != "" && $2 != "swap" && ($3 == "part" || $3 == "disk") { print $1; exit }')"
  [[ -n "$child" ]] && device="$child"
fi

mount -t auto -o rw,noatime,lazytime "$device" "$mountpoint"

# Never format or repartition the user's disk. Ensure the webdav directory exists
# with appropriate permissions for the configured admin user.
if [[ ! -d "$mountpoint/webdav" ]]; then
  mkdir -m 0775 "$mountpoint/webdav" 2>/dev/null || mkdir "$mountpoint/webdav" 2>/dev/null || true
fi
chmod 0775 "$mountpoint/webdav" 2>/dev/null || true
chown "$user:users" "$mountpoint/webdav" 2>/dev/null || true
