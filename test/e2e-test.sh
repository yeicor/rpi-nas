#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "=== Starting Comprehensive E2E Appliance Test ==="

TEST_DIR="$(mktemp -d /tmp/appliance-test-XXXXXX)"
trap 'echo "==> Cleaning up test environment"; docker rm -f qemu-test-vm 2>/dev/null || true; rm -rf "$TEST_DIR"' EXIT

# Generate ephemeral SSH key for test
mkdir -p "$TEST_DIR/ssh"
ssh-keygen -t ed25519 -N "" -f "$TEST_DIR/ssh/id_ed25519" -C "ci-test@local"
SSH_PUB="$(cat "$TEST_DIR/ssh/id_ed25519.pub")"

# Configure isolated test credentials
TEST_USER="ciadmin"
TEST_PASS="testpassword123"
TEST_HASH="$(openssl passwd -6 "$TEST_PASS")"

cat > "$TEST_DIR/config.env" <<EOF
HOSTNAME=citest
ADMIN_USERNAME=$TEST_USER
DATA_DEVICE=/dev/sda
WEBDAV_DOMAIN=citest.local
ACME_EMAIL=ci@citest.local
ADMIN_SSH_PUBLIC_KEY="$SSH_PUB"
TAILSCALE_FUNNEL=false
WIFI_SSID_1="CiPrimaryWifi"
WIFI_SSID_2="CiSecondaryWifi"
WIFI_COUNTRY="US"
EOF

cat > "$TEST_DIR/secrets.env" <<EOF
TAILSCALE_AUTH_KEY=tskey-auth-dummy-ci-key
CLOUDFLARE_API_TOKEN=cfut_dummy_ci_token
ADMIN_PAM_PASSWORD_HASH='$TEST_HASH'
WIFI_PASSWORD_1="CiPrimaryWifiPassword"
WIFI_PASSWORD_2="CiSecondaryWifiPassword"
EOF

echo "==> Building appliance image for rpi4 in Docker"
CONFIG_ENV="$TEST_DIR/config.env" SECRETS_ENV="$TEST_DIR/secrets.env" ./build.sh rpi4

# Extract kernel and initrd from built system for QEMU execution
docker run --rm \
  -v "$PWD:/app" \
  -v "$PWD/.cache/nix:/nix" \
  -v "$TEST_DIR:$TEST_DIR" \
  -w /app \
  ghcr.io/nixos/nix:latest bash -c "
    set -euo pipefail
    mkdir -p /etc
    cat << 'EOF_GIT' > /etc/gitconfig
[safe]
	directory = *
EOF_GIT
    git config --system --add safe.directory '*' 2>/dev/null || true
    git config --global --add safe.directory '*' 2>/dev/null || true
    path=\$(nix --extra-experimental-features 'nix-command flakes' build '.#nixosConfigurations.rpi4.config.system.build.toplevel' --no-link --print-out-paths)
    cp -L \"\$path/kernel\" '$TEST_DIR/kernel'
    cp -L \"\$path/initrd\" '$TEST_DIR/initrd'
    echo \"\$path\" > '$TEST_DIR/toplevel_path'
    chown -R $(id -u):$(id -g) '$TEST_DIR'
  "

INIT_PATH="$(cat "$TEST_DIR/toplevel_path")/init"

echo "==> Preparing virtual disks"
zstd -d -f result/rpi4.img.zst -o "$TEST_DIR/sdcard.img"
truncate -s 1G "$TEST_DIR/nas.img"
mkfs.ext4 -F -L NAS_DATA "$TEST_DIR/nas.img"

echo "==> Launching virtual appliance in QEMU"
docker rm -f qemu-test-vm 2>/dev/null || true
docker run --name qemu-test-vm -d \
  -v "$PWD/.cache/nix:/nix" \
  -v "$PWD:/app:ro" \
  -v "$TEST_DIR:/test" \
  -p 2222:22 -p 8080:8080 \
  ghcr.io/nixos/nix:latest \
  nix --extra-experimental-features "nix-command flakes" shell nixpkgs#qemu --command \
  qemu-system-aarch64 \
    -M virt,gic-version=3 \
    -cpu cortex-a72 -m 2G -smp 4 \
    -kernel /test/kernel \
    -initrd /test/initrd \
    -append "init=$INIT_PATH console=ttyAMA0 rw loglevel=4" \
    -drive file=/test/sdcard.img,format=raw,if=none,id=sdcard -device virtio-blk-pci,drive=sdcard \
    -device virtio-scsi-pci,id=scsi0 \
    -drive file=/test/nas.img,format=raw,if=none,id=nas -device scsi-hd,bus=scsi0.0,drive=nas \
    -netdev user,id=net0,hostfwd=tcp:0.0.0.0:22-:22,hostfwd=tcp:0.0.0.0:8080-:8080 -device virtio-net-pci,netdev=net0 \
    -nographic

SSH_OPTS=(-p 2222 -i "$TEST_DIR/ssh/id_ed25519" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes)

echo "==> Waiting for SSH connectivity on port 2222"
for i in $(seq 1 60); do
  if ssh "${SSH_OPTS[@]}" -o ConnectTimeout=2 "${TEST_USER}@127.0.0.1" "appliance-status" >/dev/null 2>&1; then
    echo "==> Appliance is online and authenticated via SSH ($i attempts)"
    break
  fi
  if (( i == 60 )); then
    echo "ERROR: Timed out waiting for appliance SSH" >&2
    echo "=== SSH Verbose Output ==="
    ssh "${SSH_OPTS[@]}" -vvv -o ConnectTimeout=5 "${TEST_USER}@127.0.0.1" "appliance-status" || true
    echo "=== VM Console Logs ==="
    docker logs qemu-test-vm | tail -n 100 || true
    exit 1
  fi
  sleep 2
done

echo "==> Testing appliance-status"
ssh "${SSH_OPTS[@]}" "${TEST_USER}@127.0.0.1" "appliance-status"

echo "==> Testing SFTP read/write operations"
dd if=/dev/urandom of="$TEST_DIR/sftp-payload.bin" bs=1M count=2 status=none
ORIG_SFTP_SHA="$(sha256sum "$TEST_DIR/sftp-payload.bin" | awk '{print $1}')"

# Copy via SFTP/SCP into the NAS WebDAV data directory
scp -P 2222 -i "$TEST_DIR/ssh/id_ed25519" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "$TEST_DIR/sftp-payload.bin" "${TEST_USER}@127.0.0.1:/run/webdav-data/webdav/sftp-test.bin"

# Read back via SFTP/SCP
scp -P 2222 -i "$TEST_DIR/ssh/id_ed25519" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "${TEST_USER}@127.0.0.1:/run/webdav-data/webdav/sftp-test.bin" "$TEST_DIR/sftp-downloaded.bin"

READ_SFTP_SHA="$(sha256sum "$TEST_DIR/sftp-downloaded.bin" | awk '{print $1}')"

if [[ "$ORIG_SFTP_SHA" != "$READ_SFTP_SHA" ]]; then
  echo "ERROR: SFTP data corruption detected! ($ORIG_SFTP_SHA != $READ_SFTP_SHA)" >&2
  exit 1
fi
echo "==> SFTP read/write test PASSED (SHA256: $ORIG_SFTP_SHA)"

# Clean up sftp test file
ssh "${SSH_OPTS[@]}" "${TEST_USER}@127.0.0.1" "rm -f /run/webdav-data/webdav/sftp-test.bin"

echo "==> Testing WebDAV PAM read/write/delete operations"
dd if=/dev/urandom of="$TEST_DIR/webdav-payload.bin" bs=1M count=1 status=none
ORIG_WEBDAV_SHA="$(sha256sum "$TEST_DIR/webdav-payload.bin" | awk '{print $1}')"

# Test WebDAV PUT over HTTP (PAM Basic Auth)
echo "--- Testing WebDAV PUT ---"
if ! ssh "${SSH_OPTS[@]}" "${TEST_USER}@127.0.0.1" \
  "curl -s -f -u '$TEST_USER:$TEST_PASS' -T - http://127.0.0.1:8080/webdav-test.bin" < "$TEST_DIR/webdav-payload.bin"; then
  echo "=== Lighttpd Journal Logs ==="
  ssh "${SSH_OPTS[@]}" "${TEST_USER}@127.0.0.1" "journalctl -u lighttpd -n 50 --no-pager" || true
  exit 1
fi

# Test WebDAV GET
echo "--- Testing WebDAV GET ---"
ssh "${SSH_OPTS[@]}" "${TEST_USER}@127.0.0.1" \
  "curl -s -f -u '$TEST_USER:$TEST_PASS' http://127.0.0.1:8080/webdav-test.bin" > "$TEST_DIR/webdav-downloaded.bin"

READ_WEBDAV_SHA="$(sha256sum "$TEST_DIR/webdav-downloaded.bin" | awk '{print $1}')"

if [[ "$ORIG_WEBDAV_SHA" != "$READ_WEBDAV_SHA" ]]; then
  echo "ERROR: WebDAV data corruption detected! ($ORIG_WEBDAV_SHA != $READ_WEBDAV_SHA)" >&2
  exit 1
fi
echo "==> WebDAV PAM read/write test PASSED (SHA256: $ORIG_WEBDAV_SHA)"

# Test WebDAV DELETE
echo "--- Testing WebDAV DELETE ---"
ssh "${SSH_OPTS[@]}" "${TEST_USER}@127.0.0.1" \
  "curl -s -f -u '$TEST_USER:$TEST_PASS' -X DELETE http://127.0.0.1:8080/webdav-test.bin"

echo "==> Testing Transactional Live Upgrade & Reboot (deploy.sh)"
CONFIG_ENV="$TEST_DIR/config.env" ADMIN_USER="$TEST_USER" SSH_KEY="$TEST_DIR/ssh/id_ed25519" ./deploy.sh rpi4 127.0.0.1:2222 --reboot

# Verify post-reboot health
echo "==> Waiting for appliance to reboot and verify health..."
for i in $(seq 1 60); do
  if ssh "${SSH_OPTS[@]}" -o ConnectTimeout=2 "${TEST_USER}@127.0.0.1" "appliance-status" >/dev/null 2>&1; then
    echo "==> Post-upgrade reboot validated successfully ($i attempts)"
    break
  fi
  if (( i == 60 )); then
    echo "ERROR: Timed out waiting for post-reboot appliance SSH" >&2
    exit 1
  fi
  sleep 2
done

ssh "${SSH_OPTS[@]}" "${TEST_USER}@127.0.0.1" "appliance-status"

echo "=== All E2E Integration Tests PASSED Successfully ==="
