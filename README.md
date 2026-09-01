# NixOS Raspberry Pi WebDAV Appliance

A resilient, secure, flash-optimized, and self-updating NixOS storage appliance for the **Raspberry Pi 4B** (`aarch64`) and **Raspberry Pi Zero W** (`armv6l`).

---

## Key Highlights

- **Flash Endurance & Immutability**: Read-only root filesystem (`ro`), volatile RAM tmpfs for `/var`, `/tmp`, and `/run`, and an auto-expanding **F2FS** `PERSIST` partition with read-only bind mounts to protect SD card lifespan.
- **Format-Agnostic Storage**: Plug-and-play swappable external drive (`/dev/sda`). Automatically detects and mounts `ext4`, `btrfs`, `xfs`, `ntfs`, `exfat`, `vfat`, or `f2fs` without reformatting or modifying existing data.
- **Multi-Network Wi-Fi**: Store up to 4 Wi-Fi networks in priority order with automatic failover and WPA2/WPA3 support. Dual-DHCP metric routing prioritizes wired Ethernet when connected.
- **Tailscale & Remote Access**: Built-in Tailscale SSH, exit-node routing, and optional Tailscale Funnel for public HTTPS exposure without router port forwarding.
- **Direct WebDAVS with Automated TLS**: Direct HTTPS WebDAV over port 443 with automated Let's Encrypt certificates (via Cloudflare DNS-01) and Dynamic DNS.
- **PAM Authentication**: Secure HTTP Basic authentication against Unix administrator credentials with zero plaintext passwords stored on flash.
- **Transactional OTA Upgrades & Rollbacks**: Remote deployments over SSH/Tailscale (`./deploy.sh`) with atomic switching, automatic garbage collection, and automated health-check rollback protection.
- **Headless Diagnostics**: Hardware UART serial console enabled by default, plus automatic diagnostic dumps to `LAST_BOOT_FAILURE.txt` on the FAT32 boot partition if boot fails (zero SD write wear during healthy boots).

---

## Architecture Overview

```text
SD Card Partitions:
├── [1] FIRMWARE (FAT32, /boot/firmware)  -> RPi firmware, U-Boot, extlinux, failure dumps
├── [2] NIXOS_SD (ext4, /)               -> Immutable OS root mounted read-only
└── [3] PERSIST  (F2FS, /persist-raw)    -> Nix store (/nix) & persistent state (/persist)
                                            (Auto-expanded to card capacity on 1st boot)

External Drive:
└── [/dev/sda] Storage Drive             -> Formatted as any filesystem; mounts to /run/webdav-data
```

---

## Quick Start

### 1. Configuration

Copy and customize the template files (all parameters and options are documented inside):

```sh
cp config.env.example config.env
cp secrets.env.example secrets.env
```

- **`config.env`** ([config.env.example](config.env.example)): System hostname, administrator username & SSH public key, external storage device path, WebDAV domain, ACME email, and optional Wi-Fi networks (up to 4 in priority order with regulatory country code).
- **`secrets.env`** ([secrets.env.example](secrets.env.example)): Tailscale auth key, Cloudflare API token, administrator PAM password hash (generate with `mkpasswd -m yescrypt` or `openssl passwd -6`), and optional Wi-Fi passphrases.

---

### 2. Build the Ready-to-Flash Image

Build images in an isolated Docker container with local caching in `.cache/nix`:

```sh
# Build for Raspberry Pi 4 (AArch64)
./build.sh rpi4

# Build for Raspberry Pi Zero W (ARMv6)
./build.sh rpi0w

# Build both targets in parallel
./build.sh all
```

Output compressed images are written to `result/rpi4.img.zst` and `result/rpi0w.img.zst`.

---

### 3. Flash to SD Card

Write the compressed image directly to your SD card (replace `/dev/sdX` with your card device):

```sh
zstdcat result/rpi4.img.zst | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

Insert the SD card and attach your external data disk (`/dev/sda`). Power on the Raspberry Pi. On the first boot, the `PERSIST` partition automatically expands to fill the SD card.

---

### 4. Remote Live Upgrades (OTA)

Deploy system updates transactionally over SSH or Tailscale without re-flashing:

```sh
./deploy.sh rpi4 rpi-webdav --reboot
```

The upgrade workflow:
1. Builds and evaluates the target closure inside Docker using persistent local caches.
2. Checks target disk space, prunes older generations (retaining active and last-known-good), and streams missing Nix store paths over SSH.
3. Transactionally switches to the new generation and reboots.
4. Performs an automated post-reboot health check (SSH, Tailscale, WebDAV). If unhealthy, it automatically rolls back to the previous generation and reboots safely.

---

## Management & Status

Connect via SSH with your configured administrator user:

```sh
ssh admin@rpi-webdav
```

Run the built-in status command for a live overview of system generation, mount topology, network IPs, Wi-Fi link state, Tailscale, and WebDAV status:

```sh
appliance-status
```

---

## Headless Diagnostics & Troubleshooting

- **Live Serial Console**: UART is enabled on GPIO 14/15 (`console=serial0,115200`) for early boot output via a USB-to-UART adapter.
- **Failure Log Dump**: If boot fails, diagnostic data (dmesg, failed units, network state, mounts) is written to `LAST_BOOT_FAILURE.txt` on the FAT32 boot partition (`/boot/firmware`). Inspect it on any computer by reading the SD card.

---

## Automated CI & Testing

An end-to-end integration test suite is provided in `test/e2e-test.sh` and runs automatically on GitHub Actions ([.github/workflows/build-and-test.yml](.github/workflows/build-and-test.yml)):

```sh
./test/e2e-test.sh
```

Tests include QEMU hardware emulation, multi-network Wi-Fi generation, SFTP read/write roundtrip, WebDAV PAM HTTP Basic operations, and live OTA deployment + rollback validation.
