#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

CONFIG_ENV="${CONFIG_ENV:-config.env}"
REBOOT=false
TARGET=""
HOST_ARG=""

usage() {
  echo "Usage: $0 <rpi0w|rpi4> <tailscale-host-or-ip> [--reboot]" >&2
  echo ""
  echo "Deploy NixOS system updates transactionally over SSH/Tailscale using Docker."
  echo ""
  echo "Arguments:"
  echo "  rpi4|rpi0w              Target hardware platform"
  echo "  <host>[:<port>]         Target device hostname, IP, or Tailscale node name"
  echo ""
  echo "Options:"
  echo "  --reboot                Automatically reboot the appliance after deploying update"
  echo ""
  echo "Environment variables:"
  echo "  CONFIG_ENV              Path to config.env (default: config.env)"
  echo "  ADMIN_USER              SSH username (defaults to ADMIN_USERNAME in config.env or 'admin')"
  echo "  SSH_KEY                 Path to identity file for SSH (-i)"
  exit 2
}

for arg in "$@"; do
  case "$arg" in
    --reboot) REBOOT=true ;;
    rpi0w|rpi4) TARGET="$arg" ;;
    --help|-h) usage ;;
    *)
      if [[ -z "$HOST_ARG" ]]; then
        HOST_ARG="$arg"
      else
        echo "Unknown argument: $arg" >&2
        usage
      fi
      ;;
  esac
done

[[ -n "$TARGET" && -n "$HOST_ARG" ]] || usage
command -v docker >/dev/null 2>&1 || { echo "Error: docker is required for deployment." >&2; exit 1; }
command -v ssh >/dev/null 2>&1 || { echo "Error: ssh is required for deployment." >&2; exit 1; }

ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
if [[ -n "${SSH_KEY:-}" ]]; then
  ssh_opts+=(-i "$SSH_KEY")
fi
if [[ "$HOST_ARG" =~ ^(.+):([0-9]+)$ ]]; then
  host="${BASH_REMATCH[1]}"
  ssh_opts+=(-p "${BASH_REMATCH[2]}")
else
  host="$HOST_ARG"
fi

admin_user="${ADMIN_USER:-}"
if [[ -z "$admin_user" && -f "$CONFIG_ENV" ]]; then
  cfg_user="$(grep -E '^ADMIN_USERNAME=' "$CONFIG_ENV" | cut -d= -f2- | tr -d ' "' || true)"
  [[ -n "$cfg_user" ]] && admin_user="$cfg_user"
fi
admin_user="${admin_user:-admin}"

mkdir -p .cache/nix .cache/xdg-cache .cache/xdg-config
if [ ! -d .cache/nix/store ]; then
  echo "==> Initializing persistent local build cache in .cache/nix..."
  docker run --rm -v "$(pwd)/.cache/nix:/host-nix" ghcr.io/nixos/nix:latest cp -a /nix/. /host-nix/
fi

HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

echo "==> Building closure for $TARGET in Docker..."
eval "$(docker run --rm \
  -v "$(pwd):/app" \
  -v "$(pwd)/.cache/nix:/nix" \
  -v "$(pwd)/.cache/xdg-cache:/root/.cache" \
  -v "$(pwd)/.cache/xdg-config:/root/.config" \
  -w /app \
  -e HOST_UID="$HOST_UID" \
  -e HOST_GID="$HOST_GID" \
  ghcr.io/nixos/nix:latest bash -c '
    set -euo pipefail
    mkdir -p /etc
    cat << "EOF_GIT" > /etc/gitconfig
[safe]
	directory = *
EOF_GIT
    git config --system --add safe.directory '*' 2>/dev/null || true
    git config --global --add safe.directory '*' 2>/dev/null || true
    path="$(nix --extra-experimental-features "nix-command flakes" build ".#nixosConfigurations.'$TARGET'.config.system.build.toplevel" --no-link --print-out-paths)"
    size="$(nix-store -q --size "$path")"
    chown -R "$HOST_UID:$HOST_GID" /app/.cache 2>/dev/null || true
    echo "TARGET_PATH=\"$path\""
    echo "CLOSURE_SIZE=\"$size\""
  ')"

echo "==> target: $TARGET"
echo "==> closure: $TARGET_PATH"
echo "==> closure bytes: $CLOSURE_SIZE"
echo "==> user: $admin_user"

echo "==> asking device to prepare its writable Nix store"
ssh "${ssh_opts[@]}" "${admin_user}@${host}" sudo appliance-prepare-update "$CLOSURE_SIZE"

echo "==> computing missing closure paths on target"
target_paths="$(ssh "${ssh_opts[@]}" "${admin_user}@${host}" 'nix-store -qR /run/current-system 2>/dev/null || true')"

echo "==> streaming missing store paths to target"
docker run --rm \
  -v "$(pwd):/app" \
  -v "$(pwd)/.cache/nix:/nix" \
  -w /app \
  ghcr.io/nixos/nix:latest bash -c '
    target_paths="'"$target_paths"'"
    all_paths="$(nix-store -qR "'"$TARGET_PATH"'")"
    missing=()
    for p in $all_paths; do
      if ! grep -Fxq "$p" <<< "$target_paths"; then
        missing+=("$p")
      fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
      nix-store --export "${missing[@]}"
    fi
  ' | ssh "${ssh_opts[@]}" "${admin_user}@${host}" sudo nix-store --import

echo "==> installing transactionally"
ssh "${ssh_opts[@]}" "${admin_user}@${host}" sudo appliance-install-generation "$TARGET_PATH"

if [[ "$REBOOT" == true ]]; then
  echo "==> rebooting $host"
  ssh "${ssh_opts[@]}" "${admin_user}@${host}" 'sudo systemctl reboot || sudo reboot' || true
  echo "==> waiting for the new generation to return"
  for _ in $(seq 1 60); do
    if ssh "${ssh_opts[@]}" "${admin_user}@${host}" true 2>/dev/null; then
      echo "==> device is reachable again"
      exit 0
    fi
    sleep 2
  done
  echo "==> timed out waiting for device reboot" >&2
  exit 1
fi
