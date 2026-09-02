#!/usr/bin/env bash
set -euo pipefail
. /persist/config.env
. /persist/secrets.env
install -d -m 0700 /persist/tailscale
if [ ! -s /persist/tailscale/authkey ]; then
  umask 077
  printf '%s\n' "$TAILSCALE_AUTH_KEY" > /persist/tailscale/authkey
fi

# The tailscaled systemd unit should be overridden to use --statedir=/persist/tailscale
if ! tailscale ip -4 >/dev/null 2>&1; then
  tailscale up --auth-key=file:/persist/tailscale/authkey --hostname="$HOSTNAME" --ssh --accept-dns=true --advertise-exit-node
else
  tailscale set --ssh=true --advertise-exit-node=true
fi
