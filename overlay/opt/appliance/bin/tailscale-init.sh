#!/usr/bin/env bash
set -euo pipefail

. /persist/config.env
. /persist/secrets.env

install -d -m 0700 /persist/tailscale
state_file="/persist/tailscale/tailscaled.state"
last_key_file="/persist/tailscale/last_authkey"
current_key="${TAILSCALE_AUTH_KEY:-}"

authkey_changed=false
if [ ! -s "$state_file" ]; then
  # No persisted state at all -> must log in
  echo "tailscale-init: No persisted state; will authenticate."
elif [ -n "$current_key" ] && [ "$current_key" != "REPLACE_ME" ]; then
  if [ -f "$last_key_file" ]; then
    last_key="$(cat "$last_key_file" 2>/dev/null || true)"
    if [ "$current_key" != "$last_key" ]; then
      echo "tailscale-init: Detected updated TAILSCALE_AUTH_KEY in secrets.env."
      authkey_changed=true
    fi
  fi
fi

# Wait until tailscaled's local socket is available so CLI commands work.
# NOTE: 'tailscale status' exits 1 BOTH when tailscaled is down AND when the
# node is logged out, so we can't use it to detect readiness. Wait on the
# socket file instead.
wait_tailscaled() {
  local sock="${TS_SOCKET:-/run/tailscale/tailscaled.sock}"
  for _ in $(seq 1 30); do
    [ -S "$sock" ] && return 0
    sleep 1
  done
  return 0
}

# tailscale status prints "Logged out." when the persisted node key exists but
# is no longer authorized (machineAuthorized=false). Poll until tailscaled has
# settled on a concrete state (instead of a transient connect error), then
# report whether the node requires login.
is_logged_out() {
  local out
  local i
  for i in $(seq 1 20); do
    out="$(tailscale status 2>&1 || true)"
    if [[ "$out" == *"Logged out"* ]]; then
      return 0
    fi
    if [[ -z "$out" ]] || [[ "$out" == *"failed to connect"* ]] || [[ "$out" == *"no state"* ]]; then
      sleep 1
      continue
    fi
    # Real status (peers listed) => logged in, not logged out
    return 1
  done
  # Couldn't get a definitive state; assume logged out so we re-auth if possible
  return 0
}

has_key() {
  [ -n "${current_key:-}" ] && [ "$current_key" != "REPLACE_ME" ]
}

do_login() {
  echo "tailscale-init: Authenticating node with auth key..."
  timeout 30 tailscale up --auth-key="$current_key" --hostname="$HOSTNAME" --ssh --accept-dns=true --advertise-exit-node || \
    echo "tailscale-init: Warning: tailscale up timed out (node may need admin approval at https://login.tailscale.com/admin)"
  if has_key; then
    printf '%s' "$current_key" > "$last_key_file"
  fi
}

if $authkey_changed || [ ! -s "$state_file" ]; then
  if has_key; then
    do_login
  else
    echo "tailscale-init: No persisted state and no auth key; manual login required: tailscale up"
  fi
elif has_key; then
  # State exists; record the authkey used for it if we haven't seen one yet
  if [ ! -f "$last_key_file" ]; then
    printf '%s' "$current_key" > "$last_key_file"
  fi

  echo "tailscale-init: Reusing persisted pre-authorized credentials from $state_file..."
  wait_tailscaled

  if is_logged_out; then
    echo "tailscale-init: Persisted node is logged out / not authorized. Re-authenticating..."
    # The persisted state has an unauthorized node key; reset it so a fresh
    # node is registered with the auth key.
    tailscale logout >/dev/null 2>&1 || true
    rm -f "$state_file"
    do_login
  fi
else
  # No auth key provided; just start tailscaled with whatever state exists
  wait_tailscaled || true
fi

# Ensure preferred settings are applied regardless of path taken
tailscale set --ssh=true --advertise-exit-node=true 2>/dev/null || true
