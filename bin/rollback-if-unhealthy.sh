#!/usr/bin/env bash
set -euo pipefail

state=/persist/update
[[ -s "$state/pending" ]] || exit 0
[[ -s "$state/booted-marker" ]] && {
  cp "$state/pending" "$state/last-successful"
  rm -f "$state/pending" "$state/previous-generation" "$state/booted-marker"
  exit 0
}

sleep 5
[[ -s "$state/booted-marker" ]] && exit 0

previous="$(cat "$state/previous-generation" 2>/dev/null || true)"
[[ "$previous" =~ ^[0-9]+$ ]] || exit 1

mount -o remount,rw /
mount -o remount,bind,rw /nix
mount -o remount,bind,rw /persist
trap 'mount -o remount,bind,ro /persist 2>/dev/null || true; mount -o remount,bind,ro /nix 2>/dev/null || true; mount -o remount,ro / 2>/dev/null || true' EXIT

nix-env --profile /nix/var/nix/profiles/system --switch-generation "$previous"
/nix/var/nix/profiles/system-${previous}-link/bin/switch-to-configuration boot
printf 'rolled back to generation %s\n' "$previous" > "$state/rollback"
rm -f "$state/pending" "$state/booted-marker"
sync
mount -o remount,bind,ro /persist
mount -o remount,bind,ro /nix
mount -o remount,ro /
reboot
