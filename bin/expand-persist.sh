#!/usr/bin/env bash
set -euo pipefail

root_dev="$(readlink -f /dev/disk/by-label/NIXOS_SD 2>/dev/null || true)"
[[ -n "$root_dev" && -b "$root_dev" ]] || exit 0
sd_dev="/dev/$(lsblk -no PKNAME "$root_dev" 2>/dev/null || true)"
persist_dev="$(readlink -f /dev/disk/by-label/PERSIST 2>/dev/null || true)"

[[ -n "$sd_dev" && -b "$sd_dev" && -n "$persist_dev" && -b "$persist_dev" ]] || exit 0
persist_part="$(lsblk -no PARTNUM "$persist_dev" 2>/dev/null || true)"
last_part="$(sfdisk -J "$sd_dev" 2>/dev/null | jq -r '[.partitiontable.partitions[].partno] | max' 2>/dev/null || true)"
[[ -n "$persist_part" && "$persist_part" == "$last_part" ]] || exit 0

end="$(blockdev --getsz "$sd_dev" 2>/dev/null || true)"
start="$(lsblk -no START "$persist_dev" 2>/dev/null || true)"
sectors="$(lsblk -no SECTORS "$persist_dev" 2>/dev/null || true)"
[[ -n "$end" && -n "$start" && -n "$sectors" ]] || exit 0
current_end=$((start + sectors))

if (( current_end < end )); then
  echo "Expanding PERSIST partition $persist_dev to end of SD device"
  echo ",+" | sfdisk -N "$persist_part" --no-reread "$sd_dev" 2>/dev/null || true
  partprobe "$sd_dev" 2>/dev/null || true
  udevadm settle 2>/dev/null || true
  sleep 1
fi

# resize.f2fs is safe to run repeatedly; it uses the current device size.
resize.f2fs "$persist_dev" 2>/dev/null || true
