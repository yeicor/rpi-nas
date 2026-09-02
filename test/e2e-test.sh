#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "=== Starting E2E Appliance Build & Verification Test ==="

TEST_DIR="$(mktemp -d /tmp/appliance-test-XXXXXX)"
trap 'echo "==> Cleaning up test environment"; rm -rf "$TEST_DIR"' EXIT

# Configure test credentials
TEST_USER="ciadmin"
TEST_PASS="testpassword123"
TEST_HASH="$(openssl passwd -6 "$TEST_PASS")"

cat > "$TEST_DIR/config.env" <<EOF
HOSTNAME=citest
ADMIN_USERNAME=$TEST_USER
DATA_DEVICE=/dev/sda
WEBDAV_DOMAIN=citest.local
ACME_EMAIL=ci@citest.local
ADMIN_SSH_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICtestkeyfordeploymentcitestci"
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

echo "==> Building appliance image..."
CONFIG_ENV="$TEST_DIR/config.env" SECRETS_ENV="$TEST_DIR/secrets.env" ./build.sh

echo "==> Verifying output artifact..."
if [[ ! -f "result/rpi4.img.zst" ]]; then
  echo "Error: result/rpi4.img.zst not found!"
  exit 1
fi

echo "==> Decompressing image to verify partition structure..."
zstd -d -f result/rpi4.img.zst -o "$TEST_DIR/rpi4.img"

echo "==> Inspecting partitions with parted in Docker..."
docker run --rm -v "$TEST_DIR:/work" debian:bookworm bash -c 'apt-get update -qq && apt-get install -y -qq parted >/dev/null 2>&1 && parted -s /work/rpi4.img print'

echo "=== E2E Build & Verification Test Passed Successfully! ==="
