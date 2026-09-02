#!/usr/bin/env bash
set -euo pipefail

boot_mnt="/boot/firmware"
status_file="$boot_mnt/status.txt"
log_file="/persist/rollback-failure.log"

status=""
[[ -f "$status_file" ]] && status="$(grep -E '^boot_status=' "$status_file" | cut -d= -f2-)"

if [[ "$status" == "testing" ]]; then
  echo "rollback: system failed health validation in testing mode. Collecting diagnostics..."
  
  # Collect diagnostics to persistent partition
  mkdir -p /persist
  {
    echo "================================================================================"
    echo "APPLIANCE AUTOMATIC ROLLBACK REPORT"
    echo "Timestamp: $(date -u)"
    echo "Kernel: $(uname -a)"
    echo "Uptime: $(uptime)"
    echo "Previous Boot Status: $status"
    echo "================================================================================"
    echo ""
    echo "--- FAILED SYSTEMD UNITS ---"
    systemctl --failed --no-pager 2>&1 || true
    echo ""
    echo "--- CRITICAL APPLIANCE SERVICES STATUS ---"
    systemctl status tailscaled lighttpd hd-idle appliance-wifi appliance-health --no-pager 2>&1 || true
    echo ""
    echo "--- NETWORK & REGULATORY STATUS ---"
    ip -br addr 2>&1 || true
    echo ""
    iw reg get 2>&1 || true
    rfkill list all 2>&1 || true
    echo ""
    echo "--- RECENT SYSTEMD JOURNAL LINES (LAST 250) ---"
    journalctl -b -n 250 --no-pager 2>&1 || true
    echo ""
    echo "--- KERNEL DMESG BUFFER (LAST 100 LINES) ---"
    dmesg -T 2>&1 | tail -n 100 || true
    echo ""
    echo "================================================================================"
    echo "END OF ROLLBACK REPORT"
    echo "================================================================================"
  } > "$log_file" 2>/dev/null || true
  sync

  echo "rollback: diagnostics saved to $log_file. Swapping Btrfs subvolumes..."
  
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
