#!/usr/bin/env bash
set -euo pipefail
. /persist/config.env
[[ "${TAILSCALE_FUNNEL:-true}" == true ]] || exit 0
/run/current-system/sw/bin/tailscale funnel --yes --bg --https=443 http://127.0.0.1:8080
