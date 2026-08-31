# NixOS Raspberry Pi WebDAV appliance

This repository builds two Raspberry Pi appliance images:

- `rpi0w`: original Raspberry Pi Zero W, ARMv6/32-bit.
- `rpi4`: Raspberry Pi 4B, AArch64.

The design is intentionally appliance-like:

- the NixOS root filesystem is **read-only during normal operation**;
- the only writable SD-card filesystem is an **F2FS PERSIST partition**;
- PERSIST is automatically expanded to the physical end of the SD card;
- `/persist` and `/nix` are exposed to the normal system as **read-only bind mounts**;
- only explicitly privileged maintenance services receive writable bind mounts into PERSIST;
- the Nix store is on PERSIST, so OTA updates do not depend on a fixed-size OTA partition;
- OS updates are performed remotely and transactionally over SSH/Tailscale;
- the previous generation is retained for rollback;
- WebDAV data is on a completely separate, swappable `/dev/sda` device;
- lighttpd authenticates through PAM;
- Tailscale provides SSH, Funnel, and exit-node advertising;
- Cloudflare provides DNS-01 validation and dynamic DNS for direct WebDAVS;
- the SSH MOTD contains this entire document.

## Storage model

The SD card contains three partitions:

1. `FIRMWARE` — Raspberry Pi firmware and bootloader files.
2. `NIXOS_SD` — immutable NixOS root filesystem, ext4, mounted `ro`.
3. `PERSIST` — F2FS, containing the Nix store and persistent appliance state.

Only partition 3 is writable at runtime. Its initial size is calculated from the actual NixOS runtime closure plus safety headroom. On first boot, the partition and F2FS filesystem are expanded to the physical end of the SD card.

Therefore an 8 GiB, 16 GiB, 32 GiB, etc. card all use the same image. The fixed immutable portions remain fixed and all remaining capacity becomes PERSIST.

The writable partition is deliberately not a generic always-writable `/var` or `/home`. The normal system sees only read-only bind mounts:

```text
physical SD F2FS
    /run/persist-rw/
        nix/
        state/
             ssh/
             tailscale/
             acme/
             cloudflare/
             update/

normal namespace:
    /nix     -> read-only bind of persist-rw/nix
    /persist -> read-only bind of persist-rw/state
```

The backing `/run/persist-rw` mount is root-only. Ordinary services and the `admin` shell therefore cannot accidentally write the SD card through the normal paths.

Linux bind mounts support exactly this read-only view of a writable filesystem; a read-only bind does not require the underlying filesystem to be mounted read-only. This lets the appliance selectively expose writable paths to only the services that need them.

## What may write to the SD card

Normal operation is designed so that persistent writes happen only in these cases:

- **Explicit remote OS deployment**: new Nix store paths, Nix profile generation metadata, and bootloader generation files.
- **Tailscale**: node identity/state and key rotation.
- **ACME**: certificate/account/renewal state when a certificate needs to be issued or renewed.
- **SSH initialization**: host keys and the configured administrator authorized key, only when they change or are first created.
- **PAM password state**: only when the configured WebDAV/admin password hash changes.
- **Cloudflare DDNS state**: only if future configuration adds persistent state; the supplied updater itself performs no local state write when the IP is unchanged.

Everything else is intentionally volatile or read-only:

- `/` is read-only.
- `/nix` is read-only except during deployment.
- `/persist` is read-only except in narrowly scoped service namespaces.
- `/var` is tmpfs.
- `/tmp` is tmpfs.
- `/run` is tmpfs.
- journald uses volatile storage.
- lighttpd's WebDAV property/lock SQLite database is in `/run` rather than on flash.
- periodic `fstrim` is disabled.
- there is no automatic Nix garbage collection or optimisation.

## Nix store and OTA updates

The complete runtime Nix closure is stored on PERSIST rather than the fixed root partition. This is important: a fixed-size OTA partition would eventually make otherwise valid updates fail merely because the new closure grew.

The PERSIST partition grows to fill the target SD card, so OTA capacity scales with the card size.

Nix is content-addressed, so generations normally share unchanged store paths. The updater also performs capacity-aware garbage collection before deployment while retaining the current and last-known-good generations.

The updater never deletes the currently running generation or the last-known-good generation before installing the candidate.

## Remote deployment

The Pi Zero W is not expected to compile its own NixOS system. Build the ARMv6 closure on a suitable build machine and deploy it remotely.

```sh
./deploy.sh rpi0w rpi-webdav --reboot
```

or:

```sh
./deploy.sh rpi4 rpi-webdav --reboot
```

The process is:

1. Build the exact target NixOS system closure on the build machine.
2. Calculate its required store size.
3. Connect to the Pi over SSH/Tailscale.
4. Temporarily make `/nix` and `/` writable **only for the deployment operation**.
5. Garbage-collect old generations while retaining current and last-known-good.
6. Refuse the deployment if there is not enough free PERSIST space plus safety margin.
7. Import the new closure.
8. Create a new NixOS generation.
9. Record the previous generation and candidate in persistent update state.
10. Regenerate the extlinux boot entry.
11. Flush writes.
12. Immediately return `/nix`, `/persist`, and `/` to read-only views.
13. Optionally reboot.
14. After reboot, health-check Tailscale, SSH, and WebDAV.
15. Confirm the candidate if healthy.
16. Otherwise roll back to the previous generation and reboot.

The deployment command does not modify `/dev/sda`.

### Manual deployment without reboot

```sh
./deploy.sh rpi4 rpi-webdav
```

Then:

```sh
ssh admin@rpi-webdav sudo reboot
```

### Manual generation inspection

```sh
ssh admin@rpi-webdav sudo nix-env --list-generations --profile /nix/var/nix/profiles/system
```

The system profile lives on PERSIST, so generation metadata survives reboot.

## Rollback guarantees

The automatic health check protects failures after the new kernel/initrd has successfully reached NixOS userspace.

It checks:

- `tailscaled.service` is active;
- the node has a Tailscale IPv4 address;
- `sshd.service` is active;
- `lighttpd.service` is active.

The external `/dev/sda` data disk is intentionally not required for OS-health success, because the data disk is independently swappable.

A kernel/initrd that cannot reach userspace cannot execute a userspace health-check rollback. Raspberry Pi images use the firmware → U-Boot → extlinux boot path; previous NixOS generations remain available in extlinux for manual selection/recovery.

## WebDAV

lighttpd uses its PAM backend:

```text
auth.backend = "pam"
auth.backend.pam.opts = ( "service" => "lighttpd" )
```

There is no htpasswd/WebDAV-specific credential database.

The configured administrator password hash is persisted on PERSIST and copied into the volatile `/etc/shadow` overlay at boot. SSH password authentication is separately disabled; the same Unix account can therefore have a WebDAV password without exposing password-based SSH.

### Filesystem permissions

The WebDAV document root is on the separate `/dev/sda` filesystem. The appliance never formats, repartitions, UUID-pins, or recursively `chown`s that disk.

If `/dev/sda` is a partitioned disk, the first child with a recognized filesystem is selected. The filesystem type is detected by Linux and mounted using `mount -t auto`.

The appliance creates only:

```text
/webdav
```

inside the selected data filesystem when it does not already exist.

Existing ownership, modes, ACLs, and extended attributes are otherwise left alone.

Important limitation: lighttpd PAM authenticates the HTTP username but does not impersonate that user for filesystem I/O. Therefore Unix DAC/ACL checks are performed using the Unix identity under which lighttpd operates. PAM authentication does not turn an HTTP username into a per-request Unix UID. If multiple HTTP users must map to different filesystem UIDs, lighttpd + PAM alone is not sufficient.

### Direct WebDAVS

```text
https://WEBDAV_DOMAIN/
```

lighttpd terminates TLS on TCP 443 using a Let's Encrypt certificate obtained through Cloudflare DNS-01.

Your router must forward TCP 443 to the Pi for this endpoint.

### Tailscale Funnel

When `TAILSCALE_FUNNEL=true`, the node exposes the same WebDAV service through Tailscale Funnel:

```text
https://<node>.<tailnet>.ts.net/
```

Funnel is public Internet exposure, so PAM authentication remains enabled.

## Cloudflare

The Cloudflare API token is stored only in PERSIST and is not embedded into the Nix store.

The token must be scoped to the relevant DNS zone and DNS record operations needed by the updater/ACME flow. Prefer a scoped API token rather than a global Cloudflare API key.

The DDNS updater:

1. obtains the current public IPv4 address;
2. finds the authoritative Cloudflare zone;
3. reads the A record;
4. exits without a write if the address is unchanged;
5. otherwise creates/updates the record with `proxied=false`.

ACME uses Cloudflare DNS-01 and stores lego's account/certificate state on PERSIST. Renewal runs periodically but does not rewrite the certificate unless renewal is necessary.

## Tailscale

The appliance enables:

- Tailscale SSH;
- exit-node advertisement;
- IP forwarding/routing support;
- Funnel;
- persistent Tailscale state.

The Tailscale state directory is writable only in the `tailscaled` service namespace. The ordinary `/persist/tailscale` view remains read-only.

The first boot stores the supplied auth key in the persistent Tailscale state directory if it is not already present. Subsequent boots use the persistent node identity and do not intentionally register a new node.

The tailnet administrator must approve the advertised exit node if the tailnet policy requires approval. Funnel likewise must be allowed by the tailnet policy.

## SSH self-documentation

The complete contents of this README are installed as:

```text
/etc/motd
/etc/appliance/README.md
```

Every SSH connection therefore receives the appliance documentation automatically.

A concise status command is also available:

```sh
appliance-status
```

## Configuration

Copy the examples:

```sh
cp config.env.example config.env
cp secrets.env.example secrets.env
```

Edit `config.env`:

```text
HOSTNAME=rpi-webdav
ADMIN_USERNAME=admin
DATA_DEVICE=/dev/sda
WEBDAV_DOMAIN=webdav.example.com
ACME_EMAIL=admin@example.com
ADMIN_SSH_PUBLIC_KEY="ssh-ed25519 AAAA... admin@laptop"
TAILSCALE_FUNNEL=true
```

Edit `secrets.env`:

```text
TAILSCALE_AUTH_KEY=tskey-auth-...
CLOUDFLARE_API_TOKEN=...
ADMIN_PAM_PASSWORD_HASH='$y$j9T$...'
```

Generate the password hash on a Linux machine with:

```sh
mkpasswd -m yescrypt
```

SSH password authentication remains disabled; authentication uses SSH keys for the configured `ADMIN_USERNAME`.

## Headless Debugging & Diagnostics

If the Raspberry Pi fails to boot or reach network during first setup on real hardware:
1. **Serial Console**: Hardware UART is enabled by default (`console=serial0,115200`). Connect a USB-to-UART adapter to GPIO 14/15 for live early boot output.
2. **Failure Diagnostic Dump**: If bootstrap or core services fail, diagnostic information (dmesg, failed systemd units, network interfaces, block devices) is written to `LAST_BOOT_FAILURE.txt` on the FAT32 boot partition (`/boot/firmware`). To view it, remove the SD card and open `LAST_BOOT_FAILURE.txt` on any PC or Mac. To protect flash endurance, no diagnostic writes occur on normal healthy boots.

## Building

Pin the flake inputs for production before the first release. Then:

```sh
./build.sh rpi0w
./build.sh rpi4
```

or:

```sh
./build.sh all
```

Results:

```text
result/rpi0w.img.zst
result/rpi4.img.zst
```

The image is intentionally sized to contain the fixed partitions plus an initial PERSIST area large enough for the actual Nix runtime closure and safety headroom. When written to a larger SD card, the PERSIST partition expands automatically on first boot to consume all remaining space.

## Initial installation

Write the appropriate compressed image to the entire SD card. This destroys the destination card contents.

For example:

```sh
zstdcat result/rpi4.img.zst | sudo dd of=/dev/mmcblk0 bs=4M status=progress conv=fsync
```

Use the correct device name for the SD card. Never guess it.

After the first boot, PERSIST is expanded before it is mounted.

## Swappable `/dev/sda`

The data disk is intentionally independent from the operating system.

The appliance does not:

- require its UUID;
- require its filesystem type in advance;
- format it;
- repartition it;
- create a filesystem on it;
- recursively change ownership;
- depend on it for booting;
- modify it during OS upgrades.

This means a failed `/dev/sda` can be replaced without rebuilding or reinstalling the SD card.

## Security notes

The direct WebDAV endpoint and Funnel endpoint are Internet-facing services. Authentication is therefore mandatory.

The admin SSH key is the primary administrative credential. Root SSH login is disabled. Password authentication is disabled for SSH.

The Cloudflare API token and Tailscale auth key are supplied outside the Nix expression and injected into PERSIST after the image is built. Do not commit `config.env` or `secrets.env`.

The PERSIST backing mount is root-only. Services receive writable bind mounts only where they have an explicit reason to modify persistent state.

## Verification before production

This environment does not contain Nix, so the repository cannot truthfully claim that the final ARMv6 and AArch64 images have been built here.

On the build machine run:

```sh
nix flake check
./build.sh rpi0w
./build.sh rpi4
```

Then test, before remote-only deployment:

1. fresh boot on each Pi model;
2. automatic PERSIST expansion on an 8 GiB card;
3. reboot persistence;
4. SSH host-key persistence;
5. Tailscale node persistence;
6. exit-node approval/use;
7. Funnel;
8. direct Cloudflare HTTPS;
9. WebDAV PUT/GET/DELETE/MKCOL/PROPFIND/LOCK/UNLOCK;
10. PAM password authentication;
11. `/dev/sda` replacement with another filesystem;
12. a successful OTA deployment;
13. a deliberately broken candidate and automatic rollback;
14. a candidate that increases the Nix closure size significantly;
15. recovery using an older extlinux generation.
