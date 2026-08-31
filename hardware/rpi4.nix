{ ... }:
{
  hardware.enableRedistributableFirmware = true;
  boot.kernelParams = [ "console=serial0,115200n8" "console=tty1" ];
}
