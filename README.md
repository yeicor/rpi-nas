# Raspberry Pi WebDAV Appliance (Debian / RPi OS)

A minimal, resilient, flash-optimized, and self-updating appliance for the **Raspberry Pi 4B** (`aarch64`) based on Raspberry Pi OS / Debian Trixie.

---

## Key Highlights

- **Minimal & Maintainable**: Built directly on top of official Raspberry Pi OS Lite (upgraded to Debian Trixie) using standard systemd services and minimal shell utilities.
- **Format-Agnostic Storage**: Plug-and-play swappable external drive (`/dev/sda`). Automatically detects and mounts `ext4`, `btrfs`, `xfs`, `ntfs`, `exfat`, `vfat`, or `f2fs` to `/run/webdav-data`.
- **Multi-Network Wi-Fi**: Connects up to 4 configured Wi-Fi networks in priority order with automatic failover and WPA2/WPA3 support.
- **Tailscale & Remote Access**: Integrated Tailscale SSH, exit-node advertising, and optional Tailscale Funnel for public HTTPS exposure without port forwarding.
- **Direct WebDAV with Automated TLS**: Lighttpd WebDAV server over port 443 with automated Let's Encrypt certificates (via Cloudflare DNS-01 and Lego) and Dynamic DNS.
- **Live Delta Upgrades via Rsync (`./deploy.sh`)**: Push updates remotely over SSH in seconds. Uses Btrfs subvolume snapshots to only transmit changed files over the wire.
- **Automated Health-Check & Rollback**: Safe transactional boots. If an upgrade fails to boot or reach network health, the system automatically rolls back to the previous Btrfs subvolume.

---

## Architecture Overview

```text
SD Card Partitions:
├── [1] BOOT     (FAT32, /boot/firmware)  -> RPi firmware, kernel, cmdline.txt, status.txt
├── [2] PERSIST  (Ext4,  /persist)        -> Persistent configuration & credentials
└── [3] ROOTFS   (Btrfs, /)               -> Btrfs subvolume (@ active, @rollback backup)
                                             (Auto-expands on card)

External Drive:
└── [/dev/sda] Storage Drive             -> Formatted as any filesystem; mounts to /run/webdav-data
```

---

## Quick Start

### 1. Configuration

Copy and customize the template files:

```sh
cp config.env.example config.env
cp secrets.env.example secrets.env
```

- **`config.env`** ([config.env.example](config.env.example)): System hostname, administrator username & SSH public key, external storage device path, WebDAV domain, ACME email, and optional Wi-Fi networks.
- **`secrets.env`** ([secrets.env.example](secrets.env.example)): Tailscale auth key, Cloudflare API token, administrator password hash, and optional Wi-Fi passphrases.

---

### 2. Build the Ready-to-Flash Image

Build the appliance image in an isolated Docker container:

```sh
./build.sh
```

Output compressed image is written to `result/rpi4.img.zst`.

---

### 3. Flash to SD Card

Write the compressed image directly to your SD card (replace `/dev/sdX` with your card device):

```sh
zstdcat result/rpi4.img.zst | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

Insert the SD card and attach your external data disk (`/dev/sda`). Power on the Raspberry Pi 4.

---

### 4. Remote Live Upgrades (Delta Push)

After rebuilding the image locally with `./build.sh`, deploy minimal file deltas over SSH without re-flashing:

```sh
./deploy.sh <raspberry-pi-ip>
```

The upgrade workflow:
1. Mounts the newly built image locally.
2. Creates a live Btrfs snapshot (`@testing`) on the running Raspberry Pi.
3. Streams only the modified files to the Pi via `rsync`.
4. Atomically swaps the active `@` and `@rollback` subvolumes.
5. Reboots and performs an automatic health-check. If unhealthy, it automatically reverts to the previous subvolume.
