#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <target-ip-or-tailscale-name> [rpi4|rpi0w]"
  exit 1
fi

TARGET="$1"
DEVICE="${2:-rpi4}"
IMG="result/${DEVICE}.img.zst"

if [[ ! -f "$IMG" ]]; then
  if [[ -f "result/${DEVICE}.img" ]]; then
    IMG="result/${DEVICE}.img"
  elif [[ -f "result/rpi4.img.zst" ]]; then
    IMG="result/rpi4.img.zst"
    DEVICE="rpi4"
  elif [[ -f "result/rpi0w.img.zst" ]]; then
    IMG="result/rpi0w.img.zst"
    DEVICE="rpi0w"
  else
    echo "Error: image not found in result/. Run ./build.sh ${DEVICE} first."
    exit 1
  fi
fi

if [[ -f config.env ]]; then
  . config.env
fi
SSH_USER="${ADMIN_USERNAME:-yeicor}"

echo "==> Deploying [${DEVICE}] image to $TARGET as $SSH_USER via Docker..."

docker run --rm --privileged --net=host \
  -e DEVICE="$DEVICE" \
  -v "$HOME/.ssh:/root/.ssh:ro" \
  -v "$(pwd):/work" \
  debian:trixie bash -c "
    set -euo pipefail
    cd /work
    
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq btrfs-progs kpartx openssh-client rsync zstd >/dev/null

    IMG_RAW=\"result/\${DEVICE}.img\"
    if [[ -f \"result/\${DEVICE}.img.zst\" ]]; then
      echo \"==> Decompressing image for delta extraction...\"
      zstd -d -f result/\${DEVICE}.img.zst -o \"\$IMG_RAW\"
    fi

    echo \"==> Mounting image inside container...\"
    LOOP_DEV=\$(losetup -f --show -P \"\$IMG_RAW\")
    kpartx -a \"\$LOOP_DEV\"
    MAPPER=\"/dev/mapper/\$(basename \"\$LOOP_DEV\")\"

    cleanup() {
      echo \"==> Cleaning up container loop mounts...\"
      umount /mnt/local-root 2>/dev/null || true
      kpartx -d \"\$LOOP_DEV\" 2>/dev/null || true
      losetup -d \"\$LOOP_DEV\" 2>/dev/null || true
      rm -f \"\$IMG_RAW\" 2>/dev/null || true
    }
    trap cleanup EXIT

    mkdir -p /mnt/local-root
    mount \"\${MAPPER}p3\" /mnt/local-root -o subvol=@

    SSH_OPTS=\"-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR\"

    echo \"==> Preparing target Pi for atomic Btrfs upgrade...\"
    ssh \$SSH_OPTS \"$SSH_USER@$TARGET\" \"sudo bash -c '
      set -euo pipefail
      mkdir -p /mnt/btrfs-root
      btrfs_dev=\\\$(findmnt -n -o SOURCE /media/root-ro 2>/dev/null | cut -d\\\"[\\\" -f1)
      [[ -z \"\\\$btrfs_dev\" ]] && btrfs_dev=\\\"/dev/mmcblk0p3\\\"
      mount -t btrfs -o subvolid=5 \\\"\\\$btrfs_dev\\\" /mnt/btrfs-root
      
      btrfs subvolume delete /mnt/btrfs-root/@testing 2>/dev/null || rm -rf /mnt/btrfs-root/@testing
      btrfs subvolume delete /mnt/btrfs-root/@bad 2>/dev/null || rm -rf /mnt/btrfs-root/@bad
      
      btrfs subvolume snapshot /mnt/btrfs-root/@ /mnt/btrfs-root/@testing
    '\"

    echo \"==> Pushing deltas via rsync...\"
    set +e
    rsync -avzx --delete --numeric-ids --rsync-path=\"sudo rsync\" \
      -e \"ssh \$SSH_OPTS\" /mnt/local-root/ \"$SSH_USER@$TARGET:/mnt/btrfs-root/@testing/\"
    RSYNC_EXIT=$?
    set -e
    if [[ $RSYNC_EXIT -ne 0 && $RSYNC_EXIT -ne 23 && $RSYNC_EXIT -ne 24 ]]; then
      echo \"==> [ERROR] rsync failed with exit code $RSYNC_EXIT\"
      exit $RSYNC_EXIT
    elif [[ $RSYNC_EXIT -eq 23 || $RSYNC_EXIT -eq 24 ]]; then
      echo \"==> [WARN] rsync completed with partial transfer (exit code $RSYNC_EXIT), continuing...\"
    else
      echo \"==> rsync completed successfully\"
    fi

    echo \"==> Atomically swapping subvolumes and setting test boot status...\"
    ssh \$SSH_OPTS \"$SSH_USER@$TARGET\" \"sudo bash -c '
      set -euo pipefail
      
      btrfs subvolume delete /mnt/btrfs-root/@rollback 2>/dev/null || rm -rf /mnt/btrfs-root/@rollback
      
      mv /mnt/btrfs-root/@ /mnt/btrfs-root/@rollback
      mv /mnt/btrfs-root/@testing /mnt/btrfs-root/@
      
      mount -o remount,rw /boot/firmware
      echo \\\"boot_status=testing\\\" > /boot/firmware/status.txt
      mount -o remount,ro /boot/firmware
      
      umount /mnt/btrfs-root 2>/dev/null || true
      
      echo \\\"Upgrade staged! Rebooting into new generation...\\\"
      nohup reboot >/dev/null 2>&1 &
    '\"

    echo \"==> Staged upgrade reboot triggered!\"
    echo \"==> Waiting for device to reboot and reconnect (polling up to 300s)...\"
    sleep 12

    start_time=\$(date +%s)
    last_reported_status=\"\"
    while true; do
      current_time=\$(date +%s)
      elapsed=\$(( current_time - start_time ))
      if [[ \$elapsed -gt 300 ]]; then
        echo \"==> [ERROR] Timed out waiting for device to reconnect after 300s!\"
        exit 1
      fi

      status=\$(ssh \$SSH_OPTS -o ConnectTimeout=2 \"$SSH_USER@$TARGET\" \"cat /boot/firmware/status.txt\" 2>/dev/null | grep -E 'boot_status=' | head -n 1 | cut -d= -f2 | tr -d '\r\n' || true)

      if [[ -n \"\$status\" ]]; then
        if [[ \"\$status\" != \"\$last_reported_status\" ]]; then
          last_reported_status=\"\$status\"
          if [[ \"\$status\" == \"testing\" ]]; then
            echo \"==> Target reconnected (elapsed: \${elapsed}s). System running new generation in 'testing' mode. Waiting for health confirmation...\"
          fi
        fi

        if [[ \"\$status\" == \"confirmed\" || \"\$status\" == \"ok\" ]]; then
          echo \"==> [SUCCESS] Deployment confirmed healthy! System running verified generation (boot_status=\$status).\"
          exit 0
        elif [[ \"\$status\" == \"rolled_back\" || \"\$status\" == \"rollback_done\" ]]; then
          echo \"==> [FAILURE] Generation failed health validation and automatically rolled back (boot_status=\$status)!\"
          echo \"==> Fetching failure diagnostic report from /persist/rollback-failure.log:\"
          echo \"--------------------------------------------------------------------------------\"
          ssh \$SSH_OPTS \"$SSH_USER@$TARGET\" \"cat /persist/rollback-failure.log 2>/dev/null\" || true
          echo \"--------------------------------------------------------------------------------\"
          exit 1
        fi
      fi
      sleep 3
    done
"
