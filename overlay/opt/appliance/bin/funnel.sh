#!/usr/bin/env bash
set -euo pipefail

# Wait for Tailscale to be online
for _ in $(seq 1 30); do
  if tailscale status >/dev/null 2>&1; then break; fi
  sleep 2
done

# Check if funnel is requested
. /persist/config.env
if [[ "${TAILSCALE_FUNNEL:-false}" == "true" ]]; then
  tailscale funnel --bg 8080
else
  tailscale serve --bg 8080
fi
