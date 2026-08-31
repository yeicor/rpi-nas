#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

command -v nix >/dev/null || { echo "nix is required" >&2; exit 1; }
git config --global --add safe.directory '*' 2>/dev/null || true

mkdir -p ~/.config/nix
cat <<'EOF' > ~/.config/nix/nix.conf
extra-experimental-features = nix-command flakes
max-jobs = auto
cores = 0
EOF

for pkg in nixpkgs#zstd.bin nixpkgs#zstd nixpkgs#util-linux nixpkgs#f2fs-tools; do
  while IFS= read -r p; do
    [ -n "$p" ] && export PATH="$p/bin:$p/sbin:$PATH"
  done < <(nix --max-jobs auto --cores 0 --extra-experimental-features "nix-command flakes" build --no-link --print-out-paths "$pkg")
done

[[ -s config.env && -s secrets.env ]] || { echo "create config.env and secrets.env from the examples" >&2; exit 1; }
mkdir -p result

package_image() {
  local target="$1"
  echo "==> Packaging $target"
  local image
  image="$(readlink -f "result/${target}/sd-image"/*.img* | head -n 1)"
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp:-}"' EXIT

  if [[ "$image" == *.zst ]]; then
    zstd -d --stdout "$image" > "$tmp/image.img"
  else
    cp --reflink=auto "$image" "$tmp/image.img"
  fi

  eval "$(partx "$tmp/image.img" -o START,SECTORS --nr 3 --pairs)"
  [[ -n "${START:-}" && -n "${SECTORS:-}" ]] || { echo "image has no PERSIST partition" >&2; exit 1; }
  dd if="$tmp/image.img" of="$tmp/persist.img" bs=512 skip="$START" count="$SECTORS" status=none

  mkdir -p "$tmp/persist-tree/state"
  cp config.env "$tmp/persist-tree/state/config.env"
  cp secrets.env "$tmp/persist-tree/state/secrets.env"
  chmod 0600 "$tmp/persist-tree/state/config.env" "$tmp/persist-tree/state/secrets.env"

  sload.f2fs -f "$tmp/persist-tree" "$tmp/persist.img"
  dd conv=notrunc if="$tmp/persist.img" of="$tmp/image.img" bs=512 seek="$START" count="$SECTORS" status=none
  zstd -f -T0 "-${ZSTD_LEVEL:-6}" "$tmp/image.img" -o "result/${target}.img.zst"
  rm -rf "$tmp"
  trap - EXIT
  echo "==> result/${target}.img.zst"
}

build_one() {
  local target="$1"
  echo "==> Building $target"
  nix --max-jobs auto --cores 0 --extra-experimental-features "nix-command flakes" build ".#nixosConfigurations.${target}.config.system.build.sdImage" --out-link "result/${target}"
  package_image "$target"
}

case "${1:-all}" in
  rpi4) build_one rpi4 ;;
  rpi0w) build_one rpi0w ;;
  all)
    echo "==> Building all targets in parallel"
    nix --max-jobs auto --cores 0 --extra-experimental-features "nix-command flakes" build \
      ".#nixosConfigurations.rpi4.config.system.build.sdImage" --out-link "result/rpi4" \
      ".#nixosConfigurations.rpi0w.config.system.build.sdImage" --out-link "result/rpi0w"
    package_image rpi4
    package_image rpi0w
    ;;
  *) echo "usage: $0 {rpi4|rpi0w|all}" >&2; exit 2 ;;
esac
