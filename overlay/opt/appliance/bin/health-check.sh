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

# Retry loop waiting for services (60 seconds)
healthy=false
for i in $(seq 1 30); do
  ts_ok=false
  webdav_ok=false

  if tailscale status >/dev/null 2>&1; then
    ts_ok=true
  fi

  code="$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/ || true)"
  if [[ "$code" == "200" || "$code" == "401" || "$code" == "403" ]]; then
    webdav_ok=true
  fi

  if $ts_ok && $webdav_ok; then
    healthy=true
    break
  fi

  sleep 2
done

if ! $healthy; then
  echo "health-check: health verification failed (tailscale: $ts_ok, webdav: $webdav_ok)." >&2
  exit 1
fi

echo "health-check: generation verified successfully! Confirming boot status as 'confirmed'."
mount -o remount,rw "$boot_mnt" || true
echo "boot_status=confirmed" > "$status_file"
mount -o remount,ro "$boot_mnt" || true
