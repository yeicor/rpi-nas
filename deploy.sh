#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

usage() {
  echo "usage: $0 <rpi0w|rpi4> <tailscale-host-or-ip> [--reboot]" >&2
  exit 2
}
[[ $# -ge 2 ]] || usage

target="$1"
host_arg="$2"
reboot=false
[[ "${3:-}" == "--reboot" ]] && reboot=true
case "$target" in rpi0w|rpi4) ;; *) usage ;; esac
command -v nix >/dev/null || { echo "nix is required" >&2; exit 1; }
command -v ssh >/dev/null || { echo "ssh is required" >&2; exit 1; }

ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
if [[ "$host_arg" =~ ^(.+):([0-9]+)$ ]]; then
  host="${BASH_REMATCH[1]}"
  ssh_opts+=(-p "${BASH_REMATCH[2]}")
else
  host="$host_arg"
fi

admin_user="${ADMIN_USER:-}"
if [[ -z "$admin_user" && -f config.env ]]; then
  cfg_user="$(grep -E '^ADMIN_USERNAME=' config.env | cut -d= -f2- | tr -d ' "' || true)"
  [[ -n "$cfg_user" ]] && admin_user="$cfg_user"
fi
admin_user="${admin_user:-admin}"

path="$(nix --extra-experimental-features 'nix-command flakes' build ".#nixosConfigurations.${target}.config.system.build.toplevel" --no-link --print-out-paths)"
size="$(nix-store -q --size "$path")"

echo "==> target: $target"
echo "==> closure: $path"
echo "==> closure bytes: $size"
echo "==> user: $admin_user"

echo "==> asking device to prepare its writable Nix store"
ssh "${ssh_opts[@]}" "${admin_user}@${host}" sudo appliance-prepare-update "$size"

cleanup_remote() {
  ssh "${ssh_opts[@]}" "${admin_user}@${host}" sudo appliance-finish-update >/dev/null 2>&1 || true
}
trap cleanup_remote EXIT

echo "==> computing missing closure paths on target"
all_paths="$(nix-store -qR "$path")"
missing_paths="$(printf '%s\n' $all_paths | ssh "${ssh_opts[@]}" "${admin_user}@${host}" 'xargs sudo nix-store --check-validity --print-invalid 2>/dev/null' || true)"

if [[ -n "$missing_paths" ]]; then
  echo "==> copying missing paths over SSH"
  nix-store --export $missing_paths | ssh -C "${ssh_opts[@]}" "${admin_user}@${host}" sudo nix-store --import
else
  echo "==> target already has all required store paths"
fi

echo "==> installing transactionally"
ssh "${ssh_opts[@]}" "${admin_user}@${host}" "sudo mount -o remount,rw /; sudo mount -o remount,bind,rw /nix; sudo mount -o remount,bind,rw /persist; sudo appliance-install-generation '$path'"

trap - EXIT
ssh "${ssh_opts[@]}" "${admin_user}@${host}" sudo appliance-finish-update

if $reboot; then
  echo "==> rebooting $host"
  ssh "${ssh_opts[@]}" "${admin_user}@${host}" sudo systemctl reboot || true
  echo "==> waiting for the new generation to return"
  sleep 5
  for _ in $(seq 1 60); do
    if ssh "${ssh_opts[@]}" -o ConnectTimeout=5 "${admin_user}@${host}" appliance-status >/dev/null 2>&1; then
      echo "==> device is reachable again"
      exit 0
    fi
    sleep 5
  done
  echo "WARNING: device did not return within the expected window" >&2
  exit 1
fi

echo "==> installed but not rebooted; run: ssh ${admin_user}@${host} sudo reboot"
