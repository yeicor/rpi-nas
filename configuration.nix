{ pkgs, lib, config, ... }:

let
  persistBacking = "/persist-raw";
  persist = "/persist";
  nixBacking = "${persistBacking}/nix";
  data = "/run/webdav-data";
  scripts = {
    bootstrap = ./bin/bootstrap.sh;
    mount-data = ./bin/mount-data.sh;
    cloudflare-ddns = ./bin/cloudflare-ddns.sh;
    funnel = ./bin/funnel.sh;
    lighttpd = ./bin/lighttpd.sh;
    health = ./bin/health-check.sh;
    rollback = ./bin/rollback-if-unhealthy.sh;
    motd = ./bin/motd.sh;
    expand-persist = ./bin/expand-persist.sh;
  };
  lighttpdPkg = pkgs.lighttpd.override { enablePam = true; };
  readme = builtins.readFile ./README.md;
  rwBind = p: "${persistBacking}/state/${p}:${persist}/${p}";
in
{
  system.stateVersion = "26.05";

  networking.hostName = "rpi-webdav";
  networking.useDHCP = false;
  networking.useNetworkd = true;
  systemd.network.enable = true;
  systemd.network.networks."99-ethernet" = {
    matchConfig.Type = "ether";
    networkConfig.DHCP = "yes";
  };

  sdImage.compressImage = false;
  sdImage.expandOnBoot = false;
  sdImage.storePaths = lib.mkForce [];
  sdImage.populateRootCommands = lib.mkAfter ''
    mkdir -m 0755 -p ./files/proc ./files/sys ./files/dev ./files/persist-raw ./files/persist ./files/nix ./files/var ./files/tmp ./files/run ./files/sbin ./files/bin ./files/etc ./files/usr/lib ./files/lib/systemd ./files/usr/bin ./files/root ./files/home
    ln -sf /nix/var/nix/profiles/system/init ./files/init
    ln -sf /nix/var/nix/profiles/system/init ./files/sbin/init
    ln -sf /nix/var/nix/profiles/system/sw/bin/sh ./files/bin/sh
    ln -sf /nix/var/nix/profiles/system/sw/bin/bash ./files/bin/bash
    ln -sf /nix/var/nix/profiles/system/sw/bin/env ./files/usr/bin/env
    ln -sf /nix/var/nix/profiles/system/etc ./files/etc/static
    for f in $(ls -A ${config.system.build.etc}/etc); do
      ln -sf static/$f ./files/etc/$f
    done
    ln -sf /run/shadow ./files/etc/shadow
    ln -sf /run/passwd ./files/etc/passwd
    ln -sf /run/group ./files/etc/group
    ln -sf /nix/var/nix/profiles/system/etc/os-release ./files/usr/lib/os-release
  '';

  fileSystems."/" = lib.mkForce {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
    noCheck = true;
    options = [ "ro" "noatime" "lazytime" "commit=600" "errors=remount-ro" ];
  };

  fileSystems."/boot/firmware" = lib.mkForce {
    device = "/dev/disk/by-label/FIRMWARE";
    fsType = "vfat";
    noCheck = true;
    options = [ "noauto" "nofail" ];
  };

  # The only writable SD filesystem.  It is mounted on a root-only hidden
  # path and exposed to the normal system only through read-only bind mounts.
  fileSystems."${persistBacking}" = {
    device = "/dev/disk/by-label/PERSIST";
    fsType = "f2fs";
    neededForBoot = true;
    noCheck = true;
    options = [ "rw" "noatime" "lazytime" ];
  };

  fileSystems."${persist}" = {
    device = "${persistBacking}/state";
    fsType = "none";
    depends = [ persistBacking ];
    options = [ "bind" "ro" ];
    neededForBoot = true;
  };

  fileSystems."/nix" = {
    device = nixBacking;
    fsType = "none";
    depends = [ persistBacking ];
    options = [ "bind" "ro" ];
    neededForBoot = true;
  };

  boot.supportedFilesystems = lib.mkForce [ "btrfs" "ext4" "xfs" "ntfs" "vfat" "exfat" "f2fs" ];
  boot.zfs.forceImportRoot = false;
  boot.initrd.includeDefaultModules = false;
  boot.initrd.systemd.enable = false;
  boot.initrd.availableKernelModules = lib.mkForce [ "mmc_block" "pci-host-generic" "virtio_pci" "virtio_blk" "virtio_net" "virtio_mmio" "virtio_scsi" "usb_storage" "uas" "f2fs" ];
  boot.initrd.kernelModules = [ "pci-host-generic" "virtio_pci" "virtio_blk" "virtio_net" "virtio_mmio" "virtio_scsi" "uas" "usb_storage" "f2fs" ];

  systemd.services.expand-persist = {
    description = "Expand PERSIST F2FS to the end of the SD card";
    unitConfig.DefaultDependencies = false;
    before = [ "persist-raw.mount" ];
    wantedBy = [ "local-fs-pre.target" ];
    serviceConfig.Type = "oneshot";
    serviceConfig.RemainAfterExit = true;
    path = with pkgs; [ util-linux parted systemd f2fs-tools jq coreutils ];
    script = "${pkgs.bash}/bin/bash ${scripts.expand-persist}";
  };

  # Disable the stock root expansion/registration logic: root is immutable and
  # the Nix store/database live on PERSIST instead.
  systemd.services.expand-root-partition.enable = false;
  systemd.services.register-nix-paths.enable = false;

  # Volatile runtime state.
  fileSystems."/home" = { device = "tmpfs"; fsType = "tmpfs"; options = [ "mode=0755" "nosuid" "nodev" ]; neededForBoot = false; };
  fileSystems."/tmp" = { fsType = "tmpfs"; options = [ "mode=1777" "nosuid" "nodev" "size=128M" ]; neededForBoot = false; };
  fileSystems."/var" = { fsType = "tmpfs"; options = [ "mode=0755" "nosuid" "nodev" ]; neededForBoot = true; };

  systemd.tmpfiles.rules = [
    "d /var/log 0755 root root -"
    "d /var/lib 0755 root root -"
    "d /var/spool 0755 root root -"
    "d /var/lock 0755 root root -"
    "d /var/empty 0755 root root -"
    "d /var/lib/tailscale 0700 root root -"
    "d /var/lib/acme 0700 root root -"
    "d /var/lib/nixos 0755 root root -"
    "C+ /run/shadow 0644 root shadow - /etc/static/shadow"
    "C+ /run/passwd 0644 root root - /etc/static/passwd"
    "C+ /run/group 0644 root root - /etc/static/group"
    "z /run/shadow 0644 root shadow -"
  ];

  services.timesyncd.enable = true;
  services.resolved.enable = true;
  networking.nameservers = [ "1.1.1.1" "8.8.8.8" ];

  boot.kernelParams = [ "console=serial0,115200" "console=ttyAMA0,115200" "console=tty1" "cgroup_enable=cpuset" "cgroup_memory=1" "cgroup_enable=memory" "swapaccount=1" ];

  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
    priority = 100;
  };
  boot.kernel.sysctl = {
    "vm.swappiness" = 100;
    "vm.watermark_boost_factor" = 0;
    "vm.watermark_scale_factor" = 125;
    "vm.page-cluster" = 0;
  };
  systemd.services.f2fs-trim = {
    description = "Trim PERSIST F2FS filesystem periodically";
    serviceConfig.Type = "oneshot";
    path = [ pkgs.util-linux ];
    script = ''
      ${pkgs.util-linux}/bin/fstrim -v /persist-raw || true
    '';
  };
  services.fstrim.enable = false;

  system.etc.overlay.enable = false;
  environment.etc."machine-id".text = "b0654e815ebf49bcbe68be05fec2404e\n";

  users.mutableUsers = false;
  users.allowNoPasswordLogin = true;
  users.users.root = {
    hashedPassword = "!";
  };
  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" "shadow" ];
    hashedPassword = "!";
    home = "/home/admin";
    createHome = true;
  };
  security.sudo.wheelNeedsPassword = false;

  # Fully headless / storage appliance optimizations.
  documentation.enable = false;
  documentation.nixos.enable = false;
  documentation.man.enable = false;
  documentation.info.enable = false;
  documentation.doc.enable = false;
  programs.command-not-found.enable = false;
  fonts.fontconfig.enable = false;

  # SD-card protection.
  nix.settings.auto-optimise-store = false;
  nix.daemonCPUSchedPolicy = "idle";
  nix.daemonIOSchedClass = "idle";
  systemd.services.nix-daemon.serviceConfig.MemoryMax = "1200M";
  systemd.sockets.nix-daemon.enable = false;

  systemd.services.sshd-keygen.enable = false;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PrintMotd = true;
      PermitRootLogin = "no";
      AllowGroups = [ "wheel" ];
      StrictModes = false;
      AuthorizedKeysFile = ".ssh/authorized_keys /persist/ssh/%u/authorized_keys";
      LogLevel = "INFO";
    };
    hostKeys = [
      { path = "/persist/ssh/ssh_host_ed25519_key"; type = "ed25519"; }
      { path = "/persist/ssh/ssh_host_rsa_key"; type = "rsa"; bits = 3072; }
    ];
  };

  # sshd needs to read /persist for authorized_keys and host keys;
  # disable ProtectSystem so it can access the bind-mounted /persist path.
  systemd.services.sshd.serviceConfig.ProtectSystem = lib.mkForce false;
  systemd.services."sshd@".serviceConfig.ProtectSystem = lib.mkForce false;
  systemd.services.sshd.serviceConfig.StandardOutput = "journal+console";
  systemd.services.sshd.serviceConfig.StandardError = "journal+console";
  systemd.services.sshd.after = [ "appliance-bootstrap.service" "ssh-hostkeys.service" "persistent-shadow.service" ];
  systemd.services.sshd.wants = [ "appliance-bootstrap.service" "ssh-hostkeys.service" "persistent-shadow.service" ];

  security.pam.services.lighttpd.unixAuth = true;

  systemd.services.appliance-bootstrap = {
    description = "Initialize persistent appliance state";
    wantedBy = [ "local-fs.target" ];
    before = [ "sshd.service" "tailscaled.service" "data-mount.service" ];
    path = [ pkgs.openssh pkgs.openssl pkgs.coreutils pkgs.gnugrep pkgs.gawk pkgs.shadow ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      BindPaths = [ "${persistBacking}/state:/persist" ];
      ProtectSystem = "strict";
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
    script = "${pkgs.bash}/bin/bash -x ${scripts.bootstrap}";
  };

  systemd.services.ssh-hostkeys = {
    wantedBy = [ "sshd.service" ];
    before = [ "sshd.service" ];
    after = [ "appliance-bootstrap.service" ];
    requires = [ "appliance-bootstrap.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      BindPaths = [ (rwBind "ssh") ];
      ProtectSystem = "strict";
    };
    script = ''
      set -eu
      install -d -m 0700 /persist/ssh
      if [ ! -s /persist/ssh/ssh_host_ed25519_key ]; then
        ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -f /persist/ssh/ssh_host_ed25519_key
      fi
      if [ ! -s /persist/ssh/ssh_host_rsa_key ]; then
        ${pkgs.openssh}/bin/ssh-keygen -q -t rsa -b 3072 -N "" -f /persist/ssh/ssh_host_rsa_key
      fi
    '';
  };

  systemd.services.admin-authorized-key = {
    wantedBy = [ "sshd.service" ];
    before = [ "sshd.service" ];
    after = [ "appliance-bootstrap.service" "persistent-shadow.service" ];
    requires = [ "appliance-bootstrap.service" "persistent-shadow.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      BindPaths = [ (rwBind "ssh") ];
      ReadWritePaths = [ "/home" ];
      ProtectSystem = "strict";
    };
    script = ''
      set -euo pipefail
      . /persist/config.env
      user="''${ADMIN_USERNAME:-admin}"
      install -d -m 0700 "/persist/ssh/$user"
      install -d -m 0700 "/home/$user" "/home/$user/.ssh"
      if ! printf '%s\n' "$ADMIN_SSH_PUBLIC_KEY" | cmp -s - "/persist/ssh/$user/authorized_keys"; then
        umask 077
        printf '%s\n' "$ADMIN_SSH_PUBLIC_KEY" > "/persist/ssh/$user/authorized_keys"
        chmod 0600 "/persist/ssh/$user/authorized_keys"
      fi
      cp -f "/persist/ssh/$user/authorized_keys" "/home/$user/.ssh/authorized_keys"
      chmod 0700 "/home/$user" "/home/$user/.ssh"
      chmod 0600 "/home/$user/.ssh/authorized_keys"
      chown -R "$user:users" "/home/$user" 2>/dev/null || true
      chown -R "$user:users" "/persist/ssh/$user" 2>/dev/null || true
    '';
  };

  systemd.services.persistent-shadow = {
    wantedBy = [ "local-fs.target" ];
    after = [ "persist.mount" "appliance-bootstrap.service" ];
    before = [ "sshd.service" "lighttpd.service" ];
    requires = [ "appliance-bootstrap.service" ];
    path = [ pkgs.util-linux pkgs.gawk pkgs.coreutils pkgs.gnused ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail
      . /persist/config.env
      . /persist/secrets.env
      user="''${ADMIN_USERNAME:-admin}"
      if [ -f /etc/static/passwd ]; then
        sed "s|^admin:|$user:|g; s|/home/admin|/home/$user|g" /etc/static/passwd > /run/passwd
        chmod 0644 /run/passwd
      fi
      if [ -f /etc/static/group ]; then
        sed "s|:admin$|:$user|g; s|:admin,|:$user,|g; s|,admin,|, $user,|g; s|,admin$|,$user|g" /etc/static/group > /run/group
        chmod 0644 /run/group
      fi
      hash="''${ADMIN_PAM_PASSWORD_HASH#\'}"
      hash="''${hash%\'}"
      hash="''${hash#\"}"
      hash="''${hash%\"}"
      install -d -m 0700 /persist/auth
      printf 'root:!:19700:0:99999:7:::\n%s:%s:19700:0:99999:7:::\n' "$user" "$hash" > /persist/auth/shadow
      chmod 0600 /persist/auth/shadow
      cp -f /persist/auth/shadow /run/shadow
      chown root:shadow /run/shadow 2>/dev/null || chown root:root /run/shadow
      chmod 0644 /run/shadow
    '';
  };

  systemd.services.data-mount = {
    description = "Mount the swappable WebDAV data disk";
    wantedBy = [ "multi-user.target" ];
    after = [ "appliance-bootstrap.service" ];
    before = [ "lighttpd.service" ];
    path = [ pkgs.util-linux pkgs.coreutils pkgs.gawk pkgs.btrfs-progs pkgs.xfsprogs pkgs.e2fsprogs pkgs.dosfstools pkgs.exfatprogs pkgs.ntfs3g pkgs.f2fs-tools ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = "2min";
      ExecStop = "${pkgs.util-linux}/bin/umount ${data}";
      PrivateMounts = false;
    };
    script = "${pkgs.bash}/bin/bash ${scripts.mount-data}";
  };

  systemd.services.lighttpd = {
    description = "PAM-authenticated WebDAV server";
    wantedBy = [ "multi-user.target" ];
    after = [ "data-mount.service" "persistent-shadow.service" "acme-runtime.service" ];
    wants = [ "acme-runtime.service" ];
    requires = [ "data-mount.service" "persistent-shadow.service" ];
    serviceConfig = {
      ExecStart = "${pkgs.bash}/bin/bash ${scripts.lighttpd}";
      Restart = "on-failure";
      RestartSec = 3;
      RuntimeDirectory = "lighttpd";
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [ data ];
    };
  };

  systemd.services.acme-runtime = {
    description = "Obtain/renew Cloudflare DNS-01 certificate";
    wantedBy = [ "multi-user.target" ];
    after = [ "appliance-bootstrap.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      BindPaths = [ (rwBind "acme") ];
      ProtectSystem = "strict";
    };
    script = "${pkgs.bash}/bin/bash ${./bin/acme-runtime.sh}";
  };
  systemd.timers.acme-runtime = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "5m"; OnUnitActiveSec = "12h"; RandomizedDelaySec = "30m"; Persistent = false; };
  };

  systemd.services.cloudflare-ddns = {
    description = "Update Cloudflare A record";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ProtectSystem = "strict";
    };
    script = "${pkgs.bash}/bin/bash ${scripts.cloudflare-ddns}";
  };
  systemd.timers.cloudflare-ddns = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "2m"; OnUnitActiveSec = "5m"; RandomizedDelaySec = "2m"; Persistent = false; };
  };

  services.tailscale = {
    enable = true;
    useRoutingFeatures = "server";
    extraDaemonFlags = [ "--statedir=/persist/tailscale" ];
    extraUpFlags = [ "--ssh" "--advertise-exit-node" ];
  };
  systemd.services.tailscaled.serviceConfig = {
    BindPaths = [ (rwBind "tailscale") ];
    ProtectSystem = "strict";
  };
  systemd.services.tailscale-init = {
    wantedBy = [ "multi-user.target" ];
    after = [ "appliance-bootstrap.service" "tailscaled.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    requires = [ "tailscaled.service" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; BindPaths = [ (rwBind "tailscale") ]; ProtectSystem = "strict"; };
    script = ''
      set -euo pipefail
      . /persist/config.env
      . /persist/secrets.env
      install -d -m 0700 /persist/tailscale
      if [ ! -s /persist/tailscale/authkey ]; then
        umask 077
        printf '%s\n' "$TAILSCALE_AUTH_KEY" > /persist/tailscale/authkey
      fi
      if ! ${pkgs.tailscale}/bin/tailscale ip -4 >/dev/null 2>&1; then
        ${pkgs.tailscale}/bin/tailscale up --auth-key=file:/persist/tailscale/authkey --hostname="$HOSTNAME" --ssh --accept-dns=true --advertise-exit-node
      else
        ${pkgs.tailscale}/bin/tailscale set --ssh=true --advertise-exit-node=true
      fi
    '';
  };

  systemd.services.tailscale-funnel = {
    description = "Publish WebDAV through Tailscale Funnel";
    wantedBy = [ "multi-user.target" ];
    after = [ "tailscale-init.service" "lighttpd.service" ];
    requires = [ "tailscale-init.service" "lighttpd.service" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; ProtectSystem = "strict"; };
    script = "${pkgs.bash}/bin/bash ${scripts.funnel}";
  };

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 443 ];
    trustedInterfaces = [ "tailscale0" ];
  };

  systemd.services.appliance-health = {
    description = "Validate the booted NixOS generation";
    wantedBy = [ "multi-user.target" ];
    after = [ "tailscale-init.service" "sshd.service" ];
    serviceConfig = { Type = "oneshot"; BindPaths = [ (rwBind "update") ]; ProtectSystem = "strict"; };
    script = "${pkgs.bash}/bin/bash ${scripts.health}";
  };

  systemd.services.appliance-rollback = {
    description = "Rollback an unconfirmed remote upgrade";
    wantedBy = [ "multi-user.target" ];
    after = [ "appliance-health.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      BindPaths = [ (rwBind "update") ];
    };
    script = "${pkgs.bash}/bin/bash ${scripts.rollback}";
  };

  systemd.services.appliance-boot-failure = {
    description = "Dump diagnostic information to boot partition on failure";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      boot_mnt=""
      for m in /boot/firmware /boot; do
        if [ -d "$m" ]; then boot_mnt="$m"; break; fi
      done
      if [ -n "$boot_mnt" ]; then
        ${pkgs.util-linux}/bin/mount -o remount,rw "$boot_mnt" 2>/dev/null || true
        {
          echo "=== APPLIANCE BOOT FAILURE DIAGNOSTIC DUMP ==="
          echo "Timestamp: $(${pkgs.coreutils}/bin/date -u '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || true)"
          echo "Uptime: $(${pkgs.coreutils}/bin/uptime 2>/dev/null || true)"
          echo ""
          echo "=== Network Interfaces & Addresses ==="
          ${pkgs.iproute2}/bin/ip addr show 2>/dev/null || true
          echo ""
          echo "=== Block Devices & Filesystems ==="
          ${pkgs.util-linux}/bin/lsblk -f 2>/dev/null || true
          echo ""
          echo "=== Mounted Filesystems ==="
          ${pkgs.util-linux}/bin/mount 2>/dev/null || true
          echo ""
          echo "=== Failed Systemd Units ==="
          ${pkgs.systemd}/bin/systemctl --failed --no-pager 2>/dev/null || true
          echo ""
          echo "=== Core Service Logs ==="
          ${pkgs.systemd}/bin/journalctl -u appliance-bootstrap -u data-mount -u lighttpd -u sshd -u tailscaled --no-pager -n 100 2>/dev/null || true
          echo ""
          echo "=== Kernel Messages ==="
          ${pkgs.util-linux}/bin/dmesg | tail -n 150 2>/dev/null || true
          echo "=== END OF DUMP ==="
        } > "$boot_mnt/LAST_BOOT_FAILURE.txt"
        ${pkgs.coreutils}/bin/sync
        ${pkgs.util-linux}/bin/mount -o remount,ro "$boot_mnt" 2>/dev/null || true
      fi
    '';
  };

  environment.etc."appliance/README.md".text = readme;
  environment.etc."motd".text = readme;

  environment.systemPackages = with pkgs; [
    lighttpdPkg tailscale lego curl jq util-linux gawk f2fs-tools exfatprogs ntfs3g btrfs-progs xfsprogs e2fsprogs dosfstools iproute2
    (pkgs.writeShellScriptBin "appliance-install-generation" (builtins.readFile ./bin/appliance-install-generation.sh))
    (pkgs.writeShellScriptBin "appliance-prepare-update" (builtins.readFile ./bin/appliance-prepare-update.sh))
    (pkgs.writeShellScriptBin "appliance-finish-update" (builtins.readFile ./bin/appliance-finish-update.sh))
    (pkgs.writeShellScriptBin "appliance-status" ''
      set -e
      echo "=== appliance ==="
      echo "generation: $(readlink /run/current-system)"
      echo "root:       $(findmnt -rn -no SOURCE,FSTYPE,OPTIONS /)"
      echo "nix:        $(findmnt -rn -no SOURCE,FSTYPE,OPTIONS /nix)"
      echo "persist:    $(findmnt -rn -no SOURCE,FSTYPE,OPTIONS /persist)"
      echo "tailscale:  $(${pkgs.tailscale}/bin/tailscale status --self 2>/dev/null || true)"
      echo "data:       $(${pkgs.util-linux}/bin/findmnt -rn --target ${data} 2>/dev/null || echo not-mounted)"
      echo "webdav:     $(systemctl is-active lighttpd 2>/dev/null || true)"
      echo "funnel:     $(${pkgs.tailscale}/bin/tailscale funnel status 2>/dev/null || true)"
      echo "SD writes are disabled by read-only bind mounts except for explicitly privileged maintenance services."
      echo "Full documentation: /etc/appliance/README.md"
    '')
  ];

  services.udisks2.enable = false;
}
