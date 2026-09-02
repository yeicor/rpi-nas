#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

DEVICE="${1:-rpi4}"
CONFIG_ENV="${CONFIG_ENV:-config.env}"
SECRETS_ENV="${SECRETS_ENV:-secrets.env}"

command -v docker >/dev/null 2>&1 || { echo "Error: docker is required."; exit 1; }
[[ -f "$CONFIG_ENV" && -f "$SECRETS_ENV" ]] || { echo "Error: missing config files"; exit 1; }

mkdir -p .cache result

echo "==> Building Raspberry Pi OS Trixie Appliance image for [${DEVICE}] in Docker..."
docker run --rm -i --privileged \
  -e DEVICE="$DEVICE" \
  -v "$(pwd):/app" \
  -w /app \
  debian:bookworm bash << 'EOF_DOCKER'
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true

apt-get update -qq
apt-get install -y -qq wget xz-utils parted util-linux kpartx e2fsprogs btrfs-progs dosfstools qemu-user-static binfmt-support rsync curl zstd

if [[ "$DEVICE" == "rpi0w" || "$DEVICE" == "rpi0" ]]; then
  TARGET_DEVICE="rpi0w"
  IMG_DATE="2026-06-19"
  IMG_NAME="2026-06-18-raspios-trixie-armhf-lite"
  IMG_URL="https://downloads.raspberrypi.com/raspios_lite_armhf/images/raspios_lite_armhf-${IMG_DATE}/${IMG_NAME}.img.xz"
  LEGO_ARCH="armv6"
  QEMU_ARCH="qemu-arm"
else
  TARGET_DEVICE="rpi4"
  IMG_DATE="2026-06-19"
  IMG_NAME="2026-06-18-raspios-trixie-arm64-lite"
  IMG_URL="https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-${IMG_DATE}/${IMG_NAME}.img.xz"
  LEGO_ARCH="arm64"
  QEMU_ARCH="qemu-aarch64"
fi

if [ ! -f ".cache/${IMG_NAME}.img" ]; then
  echo "==> Downloading official Raspberry Pi OS Trixie Lite image for ${TARGET_DEVICE}..."
  wget -q --show-progress -O ".cache/${IMG_NAME}.img.xz" "$IMG_URL"
  echo "==> Decompressing base image..."
  xz -d -T0 ".cache/${IMG_NAME}.img.xz"
fi

echo "==> Preparing working image for ${TARGET_DEVICE} (3GB with Btrfs compression)..."
rm -f "result/${TARGET_DEVICE}.img" "result/${TARGET_DEVICE}.img.zst"
truncate -s 3G "result/${TARGET_DEVICE}.img"

echo "==> Partitioning image..."
parted -s "result/${TARGET_DEVICE}.img" mklabel msdos
# Partition 1: BOOT (FAT32) 512MB
parted -s "result/${TARGET_DEVICE}.img" mkpart primary fat32 4MiB 516MiB
# Partition 2: PERSIST (Ext4) 512MB
parted -s "result/${TARGET_DEVICE}.img" mkpart primary ext4 516MiB 1028MiB
# Partition 3: ROOT (Btrfs) rest of image
parted -s "result/${TARGET_DEVICE}.img" mkpart primary btrfs 1028MiB 100%

# Create loop devices if missing in docker container
mknod /dev/loop-control c 10 237 2>/dev/null || true
for i in $(seq 0 99); do mknod /dev/loop$i b 7 $i 2>/dev/null || true; done

# Mount original image to copy data
LOOP_SRC=$(losetup -f --show ".cache/${IMG_NAME}.img")
kpartx -a "$LOOP_SRC"
MAP_SRC="/dev/mapper/$(basename $LOOP_SRC)"

# Mount new image
LOOP_DST=$(losetup -f --show "result/${TARGET_DEVICE}.img")
kpartx -a "$LOOP_DST"
MAP_DST="/dev/mapper/$(basename $LOOP_DST)"

cleanup() {
  echo "==> Cleaning up loop devices..."
  kpartx -d "$LOOP_SRC" 2>/dev/null || true
  losetup -d "$LOOP_SRC" 2>/dev/null || true
  kpartx -d "$LOOP_DST" 2>/dev/null || true
  losetup -d "$LOOP_DST" 2>/dev/null || true
}
trap cleanup EXIT

sleep 2

echo "==> Formatting new partitions..."
mkfs.vfat -F 32 -n BOOT "${MAP_DST}p1"
mkfs.ext4 -F -L PERSIST "${MAP_DST}p2"
mkfs.btrfs -f -L ROOTFS "${MAP_DST}p3"

echo "==> Copying Boot partition..."
mkdir -p /mnt/src_boot /mnt/dst_boot
mount "${MAP_SRC}p1" /mnt/src_boot
mount "${MAP_DST}p1" /mnt/dst_boot

rsync -a /mnt/src_boot/ /mnt/dst_boot/

# Source configuration
. config.env
. secrets.env

echo "==> Generating cloud-init user-data and meta-data..."
ADMIN_USER="${ADMIN_USERNAME:-admin}"
ADMIN_HASH="${ADMIN_PAM_PASSWORD_HASH#\'}"
ADMIN_HASH="${ADMIN_HASH%\'}"

cat > /mnt/dst_boot/user-data << EOF_USERDATA
#cloud-config
hostname: ${HOSTNAME:-rpi-appliance}
manage_etc_hosts: true

users:
  - name: ${ADMIN_USER}
    gecos: Appliance Administrator
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    passwd: "${ADMIN_HASH}"
    ssh_authorized_keys:
      - "${ADMIN_SSH_PUBLIC_KEY}"

EOF_USERDATA

cat > /mnt/dst_boot/meta-data << EOF_METADATA
instance-id: rpi-nas-appliance-01
local-hostname: ${HOSTNAME:-rpi-appliance}
EOF_METADATA

# Copy config and secrets to boot partition for runtime access
cp config.env /mnt/dst_boot/config.env
cp secrets.env /mnt/dst_boot/secrets.env
touch /mnt/dst_boot/ssh

# Write wpa_supplicant.conf to boot partition for early Wi-Fi setup & country regulation
cat > /mnt/dst_boot/wpa_supplicant.conf << EOF_BOOT_WPA
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=${WIFI_COUNTRY:-US}
EOF_BOOT_WPA

# Configure cmdline.txt for native initramfs overlayfs read-only root protection and regulatory domain
sed -i "s|root=PARTUUID=[a-z0-9-]*|root=/dev/mmcblk0p3|" /mnt/dst_boot/cmdline.txt
sed -i "s/rootfstype=ext4/rootfstype=btrfs rootflags=subvol=@,compress=zstd:3 overlayroot=tmpfs ds=nocloud;s=\/boot\/firmware\//" /mnt/dst_boot/cmdline.txt
sed -i "s/\$/ cfg80211.ieee80211_regdom=${WIFI_COUNTRY:-US} rfkill.default_state=1/" /mnt/dst_boot/cmdline.txt

umount /mnt/src_boot /mnt/dst_boot

echo "==> Copying Root partition with transparent zstd compression..."
mkdir -p /mnt/src_root /mnt/dst_root
mount "${MAP_SRC}p2" /mnt/src_root
mount "${MAP_DST}p3" /mnt/dst_root -o compress=zstd:3

btrfs subvolume create /mnt/dst_root/@
btrfs subvolume create /mnt/dst_root/@rollback

echo "==> Rsyncing rootfs..."
rsync -a /mnt/src_root/ /mnt/dst_root/@/
umount /mnt/src_root

echo "==> Chrooting to configure appliance..."
mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
update-binfmts --enable "$QEMU_ARCH" || true
cp -f /usr/bin/qemu-aarch64-static /mnt/dst_root/@/usr/bin/ 2>/dev/null || true
cp -f /usr/bin/qemu-arm-static /mnt/dst_root/@/usr/bin/ 2>/dev/null || true

mount "${MAP_DST}p1" /mnt/dst_root/@/boot/firmware
mount -t proc /proc /mnt/dst_root/@/proc
mount -t sysfs /sys /mnt/dst_root/@/sys
mount -t devtmpfs devtmpfs /mnt/dst_root/@/dev
mount -t devpts devpts /mnt/dst_root/@/dev/pts

mkdir -p /mnt/dst_root/@/persist /mnt/dst_root/@/home

# Configure /etc/fstab with btrfs root, boot, and persist partitions
cat > /mnt/dst_root/@/etc/fstab << EOF_FSTAB
/dev/mmcblk0p3 / btrfs defaults,compress=zstd:3,subvol=@ 0 0
/dev/mmcblk0p1 /boot/firmware vfat defaults,ro 0 2
/dev/mmcblk0p2 /persist ext4 defaults,noatime 0 2
EOF_FSTAB

# Configure cloud-init NoCloud datasource
mkdir -p /mnt/dst_root/@/etc/cloud/cloud.cfg.d
cat > /mnt/dst_root/@/etc/cloud/cloud.cfg.d/99_nocloud.cfg << EOF_CLOUD
datasource_list: [ NoCloud, None ]
datasource:
  NoCloud:
    fs_label: BOOT
EOF_CLOUD

# Pre-configure NetworkManager Wi-Fi profiles
mkdir -p /mnt/dst_root/@/etc/NetworkManager/system-connections
chmod 0700 /mnt/dst_root/@/etc/NetworkManager/system-connections

for idx in 1 2 3 4; do
  ssid_var="WIFI_SSID_${idx}"
  psk_var="WIFI_PASSWORD_${idx}"
  ssid="${!ssid_var:-}"
  psk="${!psk_var:-}"

  alt_ssid_var="WIFI_${idx}_SSID"
  alt_psk_var="WIFI_${idx}_PASSWORD"
  [[ -z "$ssid" ]] && ssid="${!alt_ssid_var:-}"
  [[ -z "$psk" ]] && psk="${!alt_psk_var:-}"

  if [[ "$idx" -eq 1 && -z "$ssid" ]]; then
    ssid="${WIFI_SSID:-}"
    psk="${WIFI_PASSWORD:-}"
  fi

  if [[ -n "$ssid" && "$ssid" != "REPLACE_ME" ]]; then
    priority=$(( 50 - idx * 10 ))
    nm_file="/mnt/dst_root/@/etc/NetworkManager/system-connections/wifi-${idx}.nmconnection"
    cat > "$nm_file" <<EOF_NM
[connection]
id=${ssid}
uuid=12345678-1234-1234-1234-12345678901${idx}
type=wifi
autoconnect=true
autoconnect-priority=${priority}

[wifi]
mode=infrastructure
ssid=${ssid}

EOF_NM
    if [[ -n "$psk" && "$psk" != "REPLACE_ME" ]]; then
      cat >> "$nm_file" <<EOF_NM
[wifi-security]
key-mgmt=wpa-psk
psk=${psk}

EOF_NM
    fi
    cat >> "$nm_file" <<EOF_NM
[ipv4]
method=auto

[ipv6]
method=auto
EOF_NM
    chmod 0600 "$nm_file"
  fi
done

# Copy overlay directory into rootfs
cp -a overlay/* /mnt/dst_root/@/
chmod +x /mnt/dst_root/@/opt/appliance/bin/*.sh

cat << EOF_CHROOT > /mnt/dst_root/@/setup-chroot.sh
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

mkdir -p /etc/initramfs-tools/scripts
if [ -f /etc/initramfs-tools/initramfs.conf ]; then
  sed -i 's/MODULES=dep/MODULES=most/' /etc/initramfs-tools/initramfs.conf
else
  echo "MODULES=most" > /etc/initramfs-tools/initramfs.conf
fi
echo "btrfs" >> /etc/initramfs-tools/modules
echo "overlay" >> /etc/initramfs-tools/modules

apt-get update
apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" overlayroot cloud-init initramfs-tools btrfs-progs lighttpd lighttpd-mod-webdav lighttpd-mod-openssl rfkill iw wireless-regdb hdparm hd-idle sdparm curl iptables wpasupplicant iproute2 apache2-utils jq openssh-server

echo 'overlayroot="tmpfs:swap=0,recurse=0"' > /etc/overlayroot.conf

echo "==> Pre-generating SSH host keys..."
ssh-keygen -A 2>/dev/null || true

update-initramfs -u -k all || true

echo "auto_initramfs=1" >> /boot/firmware/config.txt

curl -fsSL https://tailscale.com/install.sh | sh

curl -fsSL "https://github.com/go-acme/lego/releases/download/v4.17.4/lego_v4.17.4_linux_${LEGO_ARCH}.tar.gz" -o lego.tar.gz
tar -xzf lego.tar.gz lego
mv lego /usr/local/bin/lego
rm lego.tar.gz

systemctl enable ssh.service systemd-time-wait-sync.service 2>/dev/null || true
systemctl enable appliance-bootstrap.service data-mount.service
systemctl enable hd-idle.service 2>/dev/null || true
systemctl enable acme-runtime.timer cloudflare-ddns.timer
systemctl enable tailscale-init.service tailscale-funnel.service
systemctl enable lighttpd.service
systemctl enable appliance-health.service appliance-rollback.service

# Disable and mask conflicting/unneeded services for headless appliance
systemctl disable resize2fs_once dphys-swapfile rpi-resize-swap-file userconfig userconf-pi systemd-networkd-wait-online 2>/dev/null || true
systemctl mask resize2fs_once dphys-swapfile rpi-resize-swap-file userconfig userconf-pi systemd-remount-fs.service systemd-growfs-root.service sshswitch.service systemd-networkd-wait-online.service systemd-rfkill.service systemd-rfkill.socket regenerate_ssh_host_keys.service sshd-keygen.service 2>/dev/null || true

echo "==> Stripping unneeded packages and bloat (headless NAS optimization)..."
apt-get purge -y --auto-remove \
  gcc* g++* cpp* make build-essential gdb dpkg-dev \
  linux-headers-* \
  firmware-atheros firmware-realtek firmware-libertas \
  mkvtoolnix triggerhappy modemmanager iso-codes man-db manpages doc-debian xauth \
  libx11* libxext* libxmuu* libxpm* libxau* libxcb* libxdmcp* \
  alsa-utils alsa-topology-conf alsa-ucm-conf \
  v4l-utils librpicam-app* rpicam-apps* 2>/dev/null || true

apt-get autoremove --purge -y

echo "==> Cleaning apt caches and temporary files..."
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* /var/cache/debconf/*-old /tmp/* /var/tmp/* /usr/share/man/* /usr/share/doc/* /usr/share/info/*
EOF_CHROOT
chmod +x /mnt/dst_root/@/setup-chroot.sh

chroot /mnt/dst_root/@ /setup-chroot.sh

rm -f /mnt/dst_root/@/setup-chroot.sh /mnt/dst_root/@/usr/bin/qemu-*-static

echo "==> Cleaning up mounts and syncing..."
umount /mnt/dst_root/@/dev/pts
umount /mnt/dst_root/@/dev
umount /mnt/dst_root/@/sys
umount /mnt/dst_root/@/proc
umount /mnt/dst_root/@/boot/firmware

sync
umount /mnt/dst_root

trap - EXIT
cleanup

echo "==> Compressing image with zstd (ultra)..."
zstd -f -T0 -19 "result/${TARGET_DEVICE}.img" -o "result/${TARGET_DEVICE}.img.zst"
rm "result/${TARGET_DEVICE}.img"

echo "==> Done. Minimal image is at result/${TARGET_DEVICE}.img.zst"
EOF_DOCKER
