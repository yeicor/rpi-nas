#!/usr/bin/env bash
set -euo pipefail

. /persist/config.env
. /persist/secrets.env

install -d -m 0700 /persist/tailscale
state_file="/persist/tailscale/tailscaled.state"
last_key_file="/persist/tailscale/last_authkey"
current_key="${TAILSCALE_AUTH_KEY:-}"

need_new_login=false
if [ ! -s "$state_file" ]; then
  need_new_login=true
elif [ -n "$current_key" ] && [ "$current_key" != "REPLACE_ME" ]; then
  # Only re-authenticate if authkey was explicitly changed by user
  if [ -f "$last_key_file" ]; then
    last_key="$(cat "$last_key_file" 2>/dev/null || true)"
    if [ "$current_key" != "$last_key" ]; then
      echo "tailscale-init: Detected updated TAILSCALE_AUTH_KEY in secrets.env."
      need_new_login=true
    fi
  else
    # First record of auth key for an existing state
    printf '%s' "$current_key" > "$last_key_file"
  fi
fi

if $need_new_login && [ -n "$current_key" ] && [ "$current_key" != "REPLACE_ME" ]; then
  echo "tailscale-init: Authenticating node with auth key..."
  timeout 30 tailscale up --auth-key="$current_key" --hostname="$HOSTNAME" --ssh --accept-dns=true --advertise-exit-node || \
    echo "tailscale-init: Warning: tailscale up timed out (node may need admin approval at https://login.tailscale.com/admin)"
  printf '%s' "$current_key" > "$last_key_file"
else
  echo "tailscale-init: Reusing persisted pre-authorized credentials from $state_file..."
  # Wait for tailscaled to connect using its persistent state
  for _ in $(seq 1 20); do
    tailscale status >/dev/null 2>&1 && break
    sleep 1
  done
  tailscale set --ssh=true --advertise-exit-node=true 2>/dev/null || true
fi
