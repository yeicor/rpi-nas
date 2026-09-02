#!/usr/bin/env bash
set -euo pipefail

boot_mnt="/boot/firmware"
status_file="$boot_mnt/status.txt"

status=""
[[ -f "$status_file" ]] && status="$(grep -E '^boot_status=' "$status_file" | cut -d= -f2-)"

# Only enforce strict health validation if an OTA upgrade is in testing mode
if [[ "$status" != "testing" ]]; then
  echo "health-check: system boot_status is '$status' (not in 'testing' mode). Skipping rollback checks."
  exit 0
fi

echo "health-check: validating newly upgraded generation..."

# Retry loop waiting for connectivity and essential services (up to 45s)
healthy=false
for i in $(seq 1 25); do
  # Check Tailscale connectivity
  if tailscale status >/dev/null 2>&1; then
    echo "health-check: Tailscale connection verified healthy."
    healthy=true
    break
  fi

  # Fallback: Check if local network default gateway is reachable
  gateway=$(ip route show default 2>/dev/null | awk '/default/ {print $3}' | head -n 1)
  if [[ -n "$gateway" ]] && ping -c 1 -W 2 "$gateway" >/dev/null 2>&1; then
    echo "health-check: Local network gateway ($gateway) reachable and responsive."
    healthy=true
    break
  fi

  sleep 2
done

if ! $healthy; then
  echo "health-check: health verification failed (neither Tailscale nor default gateway reachable)." >&2
  exit 1
fi

echo "health-check: generation verified successfully! Confirming boot status as 'confirmed'."
mount -o remount,rw "$boot_mnt" || true
echo "boot_status=confirmed" > "$status_file"
mount -o remount,ro "$boot_mnt" || true
