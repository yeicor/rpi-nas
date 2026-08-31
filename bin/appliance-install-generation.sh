#!/usr/bin/env bash
set -euo pipefail

export PATH=/run/current-system/sw/bin:/run/current-system/sw/sbin:/run/wrappers/bin:/bin:/usr/bin:$PATH

path="${1:-}"
[[ "$path" == /nix/store/* ]] || { echo "usage: appliance-install-generation /nix/store/...-nixos-system-*" >&2; exit 2; }
[[ -x "$path/bin/switch-to-configuration" ]] || { echo "not a NixOS system closure: $path" >&2; exit 1; }

profile=/nix/var/nix/profiles/system
state=/persist/update
mkdir -p "$state"

# The caller must have made / and /nix writable. No other service should ever
# perform these operations.
mount -o remount,rw /
mount -o remount,bind,rw /nix
mount -o remount,bind,rw /persist
trap 'mount -o remount,bind,ro /persist 2>/dev/null || true; mount -o remount,bind,ro /nix 2>/dev/null || true; mount -o remount,ro / 2>/dev/null || true' EXIT

current="$(readlink -f /run/current-system 2>/dev/null || true)"
if [[ "$current" == "$path" ]]; then
  echo "generation $path is already active; refreshing boot configuration"
  "$path/bin/switch-to-configuration" boot
  sync
  mount -o remount,bind,ro /persist 2>/dev/null || true
  mount -o remount,bind,ro /nix 2>/dev/null || true
  mount -o remount,ro / 2>/dev/null || true
  trap - EXIT
  exit 0
fi

current_gen="$(nix-env --profile "$profile" --list-generations 2>/dev/null | awk '$NF == "(current)" {print $1; exit}' || echo 1)"
[[ "$current_gen" =~ ^[0-9]+$ ]] || current_gen=1

# Keep the current generation and the last known-good generation rooted while
# installing the candidate. Old generations are collected only after success.
last_good=""
if [[ -s "$state/last-successful" ]]; then
  last_good="$(cat "$state/last-successful")"
fi

nix-env --profile "$profile" --set "$path"
new="$(nix-env --profile "$profile" --list-generations 2>/dev/null | awk '$NF == "(current)" {print $1; exit}' || true)"
[[ "$new" =~ ^[0-9]+$ ]] || { echo "could not determine new generation" >&2; exit 1; }

printf '%s\n' "$current_gen" > "$state/previous-generation"
printf '%s\n' "$new" > "$state/pending"
rm -f "$state/booted-marker" "$state/failed"

"$path/bin/switch-to-configuration" boot
sync
mount -o remount,bind,ro /persist
mount -o remount,bind,ro /nix
mount -o remount,ro /
trap - EXIT

echo "candidate generation $new installed; previous generation $current_gen retained"
