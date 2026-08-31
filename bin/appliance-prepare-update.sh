#!/usr/bin/env bash
set -euo pipefail

export PATH=/run/current-system/sw/bin:/run/current-system/sw/sbin:/run/wrappers/bin:/bin:/usr/bin:$PATH

required="${1:-}"
[[ "$required" =~ ^[0-9]+$ ]] || { echo "usage: appliance-prepare-update BYTES" >&2; exit 2; }

# Only the deployment path may turn these mounts writable.
mount -o remount,rw /
mount -o remount,bind,rw /nix
trap 'mount -o remount,bind,ro /nix 2>/dev/null || true; mount -o remount,ro / 2>/dev/null || true' ERR

# Reclaim old generations while retaining current and last-successful.
mkdir -p /nix/var/nix/gcroots /nix/var/nix/profiles
if [[ -e /run/current-system ]]; then
  ln -sfn "$(readlink -f /run/current-system)" /nix/var/nix/gcroots/current-system
fi
if [[ -e /run/booted-system ]]; then
  ln -sfn "$(readlink -f /run/booted-system)" /nix/var/nix/gcroots/booted-system
fi

profile=/nix/var/nix/profiles/system
if [[ -e "$profile" ]]; then
  current="$(nix-env --profile "$profile" --list-generations 2>/dev/null | awk '$NF == "(current)" {print $1; exit}' || true)"
  keep="$current"
  if [[ -s /persist/update/last-successful ]]; then
    keep="$keep $(cat /persist/update/last-successful)"
  fi

  for gen in $(nix-env --profile "$profile" --list-generations 2>/dev/null | awk '{print $1}' | sort -n); do
    case " $keep " in *" $gen "*) ;; *) nix-env --profile "$profile" --delete-generations "$gen" >/dev/null 2>&1 || true ;; esac
  done
  nix-store --gc >/dev/null 2>&1 || true
fi

free="$(df -B1 --output=avail /nix | tail -1 | tr -d ' ')"
safety=$((256 * 1024 * 1024))
if (( free < required + safety )); then
  echo "insufficient writable Nix space: need $((required + safety)) bytes, have $free" >&2
  exit 1
fi

echo "update write access enabled; $free bytes available"
