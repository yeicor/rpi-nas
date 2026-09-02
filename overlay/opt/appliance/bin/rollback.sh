#!/usr/bin/env bash
set -euo pipefail
# Rolls back the Btrfs subvolume if boot_status is testing

boot_mnt="/boot/firmware"
status_file="$boot_mnt/status.txt"

status=""
[[ -f "$status_file" ]] && status="$(grep -E '^boot_status=' "$status_file" | cut -d= -f2-)"

if [[ "$status" == "testing" ]]; then
  echo "rollback: system is unhealthy or boot failed. Rolling back..."
  
  # Mount the underlying Btrfs root
  # Find the btrfs partition (should be /dev/mmcblk0p2 usually)
  btrfs_dev=$(findmnt -n -o SOURCE / | grep -v overlay)
  
  mkdir -p /mnt/btrfs-root
  mount -t btrfs "$btrfs_dev" /mnt/btrfs-root
  
  if [[ -d "/mnt/btrfs-root/@rollback" ]]; then
    mv /mnt/btrfs-root/@ /mnt/btrfs-root/@bad
    mv /mnt/btrfs-root/@rollback /mnt/btrfs-root/@
  fi
  
  umount /mnt/btrfs-root
  
  mount -o remount,rw "$boot_mnt" || true
  echo "boot_status=rollback_done" > "$status_file"
  mount -o remount,ro "$boot_mnt" || true
  
  reboot
fi
