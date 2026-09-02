#!/usr/bin/env bash
set -euo pipefail

boot_mnt="/boot/firmware"
status_file="$boot_mnt/status.txt"

status=""
[[ -f "$status_file" ]] && status="$(grep -E '^boot_status=' "$status_file" | cut -d= -f2-)"

if [[ "$status" == "testing" ]]; then
  echo "rollback: system is unhealthy or boot failed. Rolling back..."
  
  mkdir -p /mnt/btrfs-root
  btrfs_dev=$(findmnt -n -o SOURCE /media/root-ro 2>/dev/null | cut -d'[' -f1 || echo "/dev/mmcblk0p3")
  [[ -z "$btrfs_dev" ]] && btrfs_dev="/dev/mmcblk0p3"
  
  mount -t btrfs -o subvolid=5 "$btrfs_dev" /mnt/btrfs-root
  
  if [[ -d "/mnt/btrfs-root/@rollback" ]]; then
    btrfs subvolume delete /mnt/btrfs-root/@bad 2>/dev/null || rm -rf /mnt/btrfs-root/@bad 2>/dev/null || true
    mv /mnt/btrfs-root/@ /mnt/btrfs-root/@bad
    mv /mnt/btrfs-root/@rollback /mnt/btrfs-root/@
  fi
  
  umount /mnt/btrfs-root 2>/dev/null || true
  
  mount -o remount,rw "$boot_mnt" || true
  echo "boot_status=rolled_back" > "$status_file"
  mount -o remount,ro "$boot_mnt" || true
  
  echo "rollback: rebooting back to previous generation..."
  reboot
fi
