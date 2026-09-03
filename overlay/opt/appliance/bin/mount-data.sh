#!/usr/bin/env bash
set -euo pipefail

[[ -f /persist/config.env ]] && . /persist/config.env

device="${DATA_DEVICE:-/dev/sda}"
user="${ADMIN_USERNAME:-yeicor}"
mountpoint=/run/webdav-data

install -d -m 0775 "$mountpoint"

# Wait for disk to appear (up to 30s)
for _ in $(seq 1 6); do
  [[ -b "$device" ]] && break
  sleep 5
done

if [[ ! -b "$device" ]]; then
  echo "mount-data: Data device $device not detected. Skipping data disk initialization."
  exit 0
fi

# Detect if the device is a rotational HDD and apply power management (15 min spindown)
is_rotational="$(cat /sys/block/$(basename "$device")/queue/rotational 2>/dev/null || echo "1")"
if [[ "$is_rotational" == "1" ]]; then
  echo "mount-data: HDD detected ($device). Setting APM 127 and spindown timer to 15min (-S 180)..."
  hdparm -B 127 -S 180 "$device" 2>/dev/null || true
fi

# Determine partition to mount
data_dev="$device"
if [[ "$(lsblk -dnro TYPE "$device" 2>/dev/null)" == disk && -z "$(lsblk -dnro FSTYPE "$device" 2>/dev/null)" ]]; then
  child="$(lsblk -nrpo NAME,FSTYPE,TYPE "$device" 2>/dev/null | awk '$2 != "" && $2 != "swap" && ($3 == "part" || $3 == "disk") { print $1; exit }')"
  [[ -n "$child" ]] && data_dev="$child"
fi

# Create symlink /dev/webdav-data-disk for systemd automount
ln -sfn "$data_dev" /dev/webdav-data-disk

# Mount disk initially to ensure directories and permissions are set
if ! mountpoint -q "$mountpoint"; then
  mount -t auto -o rw,noatime,lazytime,nofail "$data_dev" "$mountpoint" 2>/dev/null || true
fi

if mountpoint -q "$mountpoint"; then
  chown "$user:www-data" "$mountpoint" 2>/dev/null || true
  chmod 0775 "$mountpoint" 2>/dev/null || true
fi

# Enable systemd automount with 15min idle timeout so it auto-unmounts when idle and auto-mounts on access
systemctl start run-webdav\\x2ddata.automount 2>/dev/null || true

echo "mount-data: Data disk configured with 15-minute spindown & on-demand automount."
