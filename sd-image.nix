{ config, lib, pkgs, ... }:

let
  closureInfo = pkgs.closureInfo {
    rootPaths = [ config.system.build.toplevel ];
  };
in
# Extend the stock Raspberry Pi SD image with a third, dynamically-grown F2FS
# partition. The immutable ext4 root contains boot files and generated /etc,
# while the complete Nix closure and all mutable state live in PERSIST.
{
  sdImage.storePaths = lib.mkForce [];

  sdImage.postBuildCommands = lib.mkAfter ''
    set -euo pipefail

    # The root image is deliberately kept immutable and does not contain a
    # duplicate Nix store. Build the initial store directly into F2FS.
    closure_bytes=$(du -scb $(cat ${closureInfo}/store-paths) | tail -1 | awk '{ print $1 }')
    reserve=$((512 * 1024 * 1024))
    min_size=$((1024 * 1024 * 1024))
    # Give 40% margin for F2FS block alignment, inodes, metadata, and overprovisioning
    p3_bytes=$(( (closure_bytes * 14 / 10) + reserve ))
    if (( p3_bytes < min_size )); then p3_bytes=$min_size; fi
    # Round to 64 MiB so the image is stable and resize-friendly.
    round=$((64 * 1024 * 1024))
    p3_bytes=$(( ((p3_bytes + round - 1) / round) * round ))

    eval "$(${pkgs.buildPackages.util-linux}/bin/partx "$img" -o START,SECTORS --nr 2 --pairs)"
    p3_start=$((START + SECTORS))

    root_size=$(stat -c '%s' "$img")
    truncate -s $((root_size + p3_bytes)) "$img"

    echo "$p3_start,," | ${pkgs.buildPackages.util-linux}/bin/sfdisk --no-reread --append "$img"
    eval "$(${pkgs.buildPackages.util-linux}/bin/partx "$img" -o START,SECTORS --nr 3 --pairs)"

    truncate -s $((SECTORS * 512)) persist.img
    ${pkgs.buildPackages.f2fs-tools}/bin/mkfs.f2fs -q -l PERSIST persist.img

    mkdir -p persist-tree/nix/store persist-tree/nix/var/nix/profiles persist-tree/nix/var/nix/gcroots/auto persist-tree/nix/var/nix/db

    # Copy only the runtime closure, preserving the Nix store's symlinks and
    # modes. sload.f2fs creates the target files as root by default.
    while IFS= read -r path; do
      cp -a "$path" persist-tree/nix/store/
    done < ${closureInfo}/store-paths

    # Initial NixOS generation 1 and GC roots.
    ln -s /nix/store/${builtins.baseNameOf config.system.build.toplevel} persist-tree/nix/var/nix/profiles/system-1-link
    ln -s system-1-link persist-tree/nix/var/nix/profiles/system
    ln -s /nix/var/nix/profiles/system persist-tree/nix/var/nix/gcroots/current-system
    ln -s /nix/var/nix/profiles/system persist-tree/nix/var/nix/gcroots/booted-system

    NIX_STATE_DIR="$(pwd)/persist-tree/nix/var/nix" ${pkgs.buildPackages.nix}/bin/nix-store --load-db < ${closureInfo}/registration

    ${pkgs.buildPackages.f2fs-tools}/bin/sload.f2fs -f persist-tree persist.img
    dd conv=notrunc if=persist.img of="$img" bs=512 seek="$START" count="$SECTORS" status=none
    chmod -R u+w persist-tree 2>/dev/null || true
    rm -rf persist-tree persist.img
  '';
}
