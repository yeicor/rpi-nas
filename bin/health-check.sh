#!/usr/bin/env bash
set -euo pipefail

state=/persist/update
for _ in $(seq 1 30); do
  ok=1
  systemctl is-active --quiet tailscaled.service || ok=0
  /run/current-system/sw/bin/tailscale ip -4 >/dev/null 2>&1 || ok=0
  systemctl is-active --quiet sshd.service || ok=0
  systemctl is-active --quiet lighttpd.service || ok=0
  if (( ok == 1 )); then
    if [[ -s "$state/pending" ]]; then
      printf '%s\n' "$(readlink /run/current-system)" > "$state/booted-marker"
    fi
    exit 0
  fi
  sleep 2
done
exit 1
