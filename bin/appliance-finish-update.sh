#!/usr/bin/env bash
set -euo pipefail
export PATH=/run/current-system/sw/bin:/run/current-system/sw/sbin:/run/wrappers/bin:/bin:/usr/bin:$PATH

mount -o remount,bind,ro /persist 2>/dev/null || true
mount -o remount,bind,ro /nix 2>/dev/null || true
mount -o remount,ro / 2>/dev/null || true
sync
