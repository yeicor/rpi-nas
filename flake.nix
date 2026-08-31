{
  description = "Minimal remotely upgradable read-only NixOS Raspberry Pi WebDAV appliance";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # Pin this input in flake.lock before production deployment.
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
  };

  outputs = { self, nixpkgs, nixos-hardware }:
    let
      common = { pkgs, lib, config, ... }:
        import ./configuration.nix { inherit pkgs lib config; };
      mkSystem = { hostPlatform, buildPlatform ? "x86_64-linux", modules }: nixpkgs.lib.nixosSystem {
        modules = modules ++ [
          common
          {
            nixpkgs.buildPlatform = buildPlatform;
            nixpkgs.hostPlatform = hostPlatform;
            nixpkgs.overlays = [
              (final: prev: {
                efivar = prev.runCommand "efivar-stub" {
                  outputs = [ "out" "dev" "bin" "man" ];
                } "mkdir -p $out/lib $dev/include $bin/bin $man";
                efibootmgr = prev.runCommand "efibootmgr-stub" {
                  outputs = [ "out" "man" ];
                } "mkdir -p $out/bin $man; touch $out/bin/efibootmgr; chmod +x $out/bin/efibootmgr";
              })
            ];
            nixpkgs.config.problems.handlers.efivar.broken = "ignore";
          }
        ];
      };
    in {
      nixosConfigurations.rpi0w = mkSystem {
        hostPlatform = "armv6l-linux";
        modules = [
          "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-raspberrypi.nix"
          ./hardware/rpi0w.nix
          ./sd-image.nix
        ];
      };

      nixosConfigurations.rpi4 = mkSystem {
        hostPlatform = "aarch64-linux";
        modules = [
          "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
          nixos-hardware.nixosModules.raspberry-pi-4
          ./hardware/rpi4.nix
          ./sd-image.nix
        ];
      };

      packages.x86_64-linux = {
        rpi0w = self.nixosConfigurations.rpi0w.config.system.build.sdImage;
        rpi4 = self.nixosConfigurations.rpi4.config.system.build.sdImage;
      };
      packages.aarch64-linux = {
        rpi0w = self.nixosConfigurations.rpi0w.config.system.build.sdImage;
        rpi4 = self.nixosConfigurations.rpi4.config.system.build.sdImage;
      };
    };
}
