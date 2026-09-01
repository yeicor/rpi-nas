#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

CONFIG_ENV="${CONFIG_ENV:-config.env}"
SECRETS_ENV="${SECRETS_ENV:-secrets.env}"
TARGET="all"

for arg in "$@"; do
  case "$arg" in
    rpi4|rpi0w|all) TARGET="$arg" ;;
    --help|-h)
      echo "Usage: $0 [rpi4|rpi0w|all]"
      echo ""
      echo "Builds ready-to-flash Raspberry Pi SD images in an isolated Docker container."
      echo ""
      echo "Arguments:"
      echo "  rpi4         Build image for Raspberry Pi 4B (AArch64)"
      echo "  rpi0w        Build image for Raspberry Pi Zero W (ARMv6)"
      echo "  all          Build all targets in parallel (default)"
      echo ""
      echo "Environment variables:"
      echo "  CONFIG_ENV   Path to config.env (default: config.env)"
      echo "  SECRETS_ENV  Path to secrets.env (default: secrets.env)"
      echo "  ZSTD_LEVEL   Zstandard compression level (default: 6)"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: $0 [rpi4|rpi0w|all]" >&2
      exit 2
      ;;
  esac
done

command -v docker >/dev/null 2>&1 || { echo "Error: docker is required to build images." >&2; exit 1; }

[[ -s "$CONFIG_ENV" && -s "$SECRETS_ENV" ]] || {
  echo "Error: Missing or empty config file: $CONFIG_ENV or $SECRETS_ENV" >&2
  echo "Create them from config.env.example and secrets.env.example" >&2
  exit 1
}

# Ensure persistent local build cache directories exist in .cache/
mkdir -p .cache/nix .cache/xdg-cache .cache/xdg-config result
if [ ! -d .cache/nix/store ]; then
  echo "==> Initializing persistent local build cache in .cache/nix..."
  docker run --rm -v "$(pwd)/.cache/nix:/host-nix" ghcr.io/nixos/nix:latest cp -a /nix/. /host-nix/
fi

HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
DOCKER_INTERACTIVE=$([ -t 0 ] && echo "-it" || echo "-i")

CFG_ABS="$(readlink -f "$CONFIG_ENV")"
SEC_ABS="$(readlink -f "$SECRETS_ENV")"

DOCKER_MOUNTS=(
  -v "$(pwd):/app"
  -v "$(pwd)/.cache/nix:/nix"
  -v "$(pwd)/.cache/xdg-cache:/root/.cache"
  -v "$(pwd)/.cache/xdg-config:/root/.config"
  -v "$CFG_ABS:/run/app-config/config.env:ro"
  -v "$SEC_ABS:/run/app-config/secrets.env:ro"
)

echo "==> Building '$TARGET' in Docker (ghcr.io/nixos/nix:latest)..."

exec docker run --rm $DOCKER_INTERACTIVE \
  "${DOCKER_MOUNTS[@]}" \
  -w /app \
  -e HOST_UID="$HOST_UID" \
  -e HOST_GID="$HOST_GID" \
  -e ZSTD_LEVEL="${ZSTD_LEVEL:-6}" \
  -e TARGET="$TARGET" \
  ghcr.io/nixos/nix:latest bash -c '
    set -euo pipefail
    mkdir -p /etc
    cat << "EOF_GIT" > /etc/gitconfig
[safe]
	directory = *
EOF_GIT
    git config --system --add safe.directory '*' 2>/dev/null || true
    git config --global --add safe.directory '*' 2>/dev/null || true

    mkdir -p ~/.config/nix
    cat << "EOF_NIX" > ~/.config/nix/nix.conf
extra-experimental-features = nix-command flakes
max-jobs = auto
cores = 0
download-attempts = 5
connect-timeout = 60
stalled-download-timeout = 90
http-connections = 50
EOF_NIX

    nix_build_retry() {
      local max_attempts=5
      local attempt=1
      while true; do
        if nix --max-jobs auto --cores 0 build "$@"; then
          return 0
        fi
        if (( attempt >= max_attempts )); then
          echo "ERROR: nix build failed after $attempt attempts." >&2
          return 1
        fi
        echo "==> Build hit temporary glitch/network reset. Retrying ($attempt/$max_attempts) in $((attempt * 5))s..."
        sleep $((attempt * 5))
        attempt=$((attempt + 1))
      done
    }

    for pkg in nixpkgs#zstd.bin nixpkgs#zstd nixpkgs#util-linux nixpkgs#f2fs-tools; do
      while IFS= read -r p; do
        [ -n "$p" ] && export PATH="$p/bin:$p/sbin:$PATH"
      done < <(nix_build_retry --no-link --print-out-paths "$pkg")
    done

    package_image() {
      local t="$1"
      echo "==> Packaging $t"
      local image
      image="$(readlink -f "result/${t}/sd-image"/*.img* | head -n 1)"
      local tmp
      tmp="$(mktemp -d)"
      trap '\''rm -rf "${tmp:-}"'\'' EXIT

      if [[ "$image" == *.zst ]]; then
        zstd -d --stdout "$image" > "$tmp/image.img"
      else
        cp --reflink=auto "$image" "$tmp/image.img"
      fi

      eval "$(partx "$tmp/image.img" -o START,SECTORS --nr 3 --pairs)"
      [[ -n "${START:-}" && -n "${SECTORS:-}" ]] || { echo "image has no PERSIST partition" >&2; exit 1; }
      dd if="$tmp/image.img" of="$tmp/persist.img" bs=512 skip="$START" count="$SECTORS" status=none

      mkdir -p "$tmp/persist-tree/state"
      cp /run/app-config/config.env "$tmp/persist-tree/state/config.env"
      cp /run/app-config/secrets.env "$tmp/persist-tree/state/secrets.env"
      chmod 0600 "$tmp/persist-tree/state/config.env" "$tmp/persist-tree/state/secrets.env"

      sload.f2fs -f "$tmp/persist-tree" "$tmp/persist.img"
      dd conv=notrunc if="$tmp/persist.img" of="$tmp/image.img" bs=512 seek="$START" count="$SECTORS" status=none
      zstd -f -T0 "-${ZSTD_LEVEL}" "$tmp/image.img" -o "result/${t}.img.zst"
      rm -rf "$tmp"
      trap - EXIT
      echo "==> result/${t}.img.zst"
    }

    build_one() {
      local t="$1"
      echo "==> Building $t"
      nix_build_retry ".#nixosConfigurations.${t}.config.system.build.sdImage" --out-link "result/${t}"
      package_image "$t"
    }

    case "$TARGET" in
      rpi4) build_one rpi4 ;;
      rpi0w) build_one rpi0w ;;
      all)
        echo "==> Building all targets in parallel"
        nix_build_retry \
          ".#nixosConfigurations.rpi4.config.system.build.sdImage" --out-link "result/rpi4" \
          ".#nixosConfigurations.rpi0w.config.system.build.sdImage" --out-link "result/rpi0w"
        package_image rpi4
        package_image rpi0w
        ;;
    esac

    # Ensure generated files have matching host ownership
    chown -R "$HOST_UID:$HOST_GID" /app/result /app/.cache 2>/dev/null || true
  '
