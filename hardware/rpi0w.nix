{ pkgs, lib, ... }:
{
  # Original Pi Zero W is ARMv6, not AArch64.
  boot.kernelPackages = lib.mkForce pkgs.linuxPackages;
  boot.kernelParams = [ "console=serial0,115200n8" "console=tty1" ];
  hardware.enableRedistributableFirmware = true;
}
