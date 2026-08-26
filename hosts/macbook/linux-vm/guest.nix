# The persistent Linux workload guest, as a NixOS system.
#
# Where ../../vz-builder/guest.nix is netboot -- no disk at all, everything
# ephemeral by construction -- this one has a real root filesystem on /dev/vda,
# so container images, etcd state, home directories and logs survive a restart.
# That is the entire point of it: it hosts workloads (Kubernetes and friends)
# that must not lose their state because somebody restarted the VM.
#
# What it shares with the builder guest is the stack underneath: direct kernel
# boot through Virtualization.framework, the host's /nix/store read-only over
# virtiofs as the lower layer of a local-overlay store, keys delivered on their
# own share, NAT networking answered over mDNS. See ../../vz-builder for the
# full reasoning behind each of those; this file carries only what differs.
{
  modulesPath,
  config,
  lib,
  pkgs,
  ...
}:
let
  # Same incantation as the builder guest, for the same reason: the host store
  # is mounted read-only at /host-nix and becomes the *only* lower layer, so an
  # input this Mac has already built is referenced where it lies rather than
  # copied. `check-mount=false` is required, not papering over breakage: stage 1
  # mounts under /sysroot and the kernel keeps recording the stale
  # `lowerdir=/sysroot/...` string after the pivot, so Nix's mount check can
  # never pass. See ../../vz-builder/guest.nix for the full walk-through.
  #
  # The upper layer is a plain directory on the persistent root disk rather
  # than a separate disk: unlike the builder's, this VM's writable store layer
  # is worth keeping. Anything built or fetched inside the guest survives a
  # restart with everything else.
  overlayStoreUri = lib.concatStringsSep "" [
    "local-overlay://"
    "?lower-store=/host-nix%3Fread-only=true"
    "&upper-layer=/nix/.rw-store/store"
    "&check-mount=false"
  ];

  # Kubernetes' standard kernel prerequisites. The modules have to be loaded
  # before the sysctls are applied -- systemd-sysctl runs early and will not
  # revisit a key that did not exist yet -- so they are applied by a oneshot
  # ordered after systemd-modules-load instead of boot.kernel.sysctl.
  k8sSysctls = {
    "net.ipv4.ip_forward" = 1;
    "net.bridge.bridge-nf-call-iptables" = 1;
    "net.bridge.bridge-nf-call-ip6tables" = 1;
  };
in
{
  config = {
    system.stateVersion = "26.11";

    boot.kernelParams = [
      "console=hvc0" # vfkit's virtio-serial
      "systemd.log_level=warning"
    ];

    # The hypervisor loads the kernel directly -- there is no bootloader inside
    # this guest and nothing here installs boot entries. Without this, NixOS
    # defaults to grub and then asserts that nobody told it which disks to
    # install itself onto.
    boot.loader.grub.enable = false;

    # Same trimmed initrd as the builder: this machine has four device classes
    # and no real hardware, and the default module set costs seconds of udev
    # walking buses that do not exist here.
    boot.initrd.includeDefaultModules = false;
    boot.initrd.availableKernelModules = [
      "virtio_pci" # how every device below is discovered
      "virtio_net"
      "virtio_console" # hvc0, which the console= parameter names
      "virtio_rng"
      "fuse" # virtiofs is built on it
      "virtiofs"
      "virtio_blk" # the root disk, and the swap disk beside it
      "overlay"
    ];
    boot.kernelModules = [
      "virtiofs"
      "overlay"
      "br_netfilter"
      "ip_vs"
      "ip_vs_rr"
      "ip_vs_wrr"
      "ip_vs_sh"
      "nf_conntrack"
    ];

    # Nothing here has, or emulates, a TPM.
    boot.initrd.systemd.tpm2.enable = false;

    # The root disk, attached first so it is /dev/vda. Sparse on the host, so
    # sizing it generously costs nothing until the guest fills it. autoFormat
    # becomes x-systemd.makefs in stage 1: the first ever boot finds no
    # signature and formats, every later boot finds one and mounts. This is
    # what makes the disk persistent rather than recreated-per-start like the
    # builder's.
    boot.initrd.supportedFilesystems = [ "ext4" ];
    fileSystems."/".device = "/dev/vda";
    fileSystems."/".fsType = "ext4";
    fileSystems."/".autoFormat = true;
    fileSystems."/".neededForBoot = true;
    fileSystems."/".options = [ "noatime" ];

    # Swap, on its own persistent disk (/dev/vdb -- attached after root).
    # Persistent, so mkswap runs once behind a signature check rather than on
    # every boot; after the first boot this service only flips swapon.
    #
    # Not `swapDevices`: NixOS builds a swapfile with `dd`, which would write
    # the whole thing on every boot, while mkswap on a raw device writes only a
    # header. Same reasoning as the builder's swap disk.
    swapDevices = lib.mkForce [ ];
    systemd.services.linux-vm-swap = {
      description = "Enable the persistent swap disk";
      wantedBy = [ "multi-user.target" ];
      before = [ "nix-daemon.service" ];
      after = [ "systemd-modules-load.service" ];
      path = with pkgs; [
        util-linux
        e2fsprogs
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        blkid /dev/vdb > /dev/null 2>&1 || mkswap /dev/vdb
        swapon /dev/vdb 2> /dev/null || true
      '';
    };

    # Kubernetes' kernel prerequisites, applied after the modules above are
    # loaded. See the comment on k8sSysctls for why this is a service and not
    # boot.kernel.sysctl.
    systemd.services.linux-vm-kernel-tuning = {
      description = "Apply Kubernetes kernel prerequisites";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-modules-load.service" ];
      path = [ pkgs.procps ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (key: value: ''
          sysctl -w ${key}=${toString value}
        '') k8sSysctls
      );
    };

    # The host store and database, read-only. Both halves are needed and the
    # database mount is what the overlay store reads validity from; see
    # ../../vz-builder/guest.nix for why this is neededForBoot -- miss it and
    # the daemon silently believes every lower path is invalid.
    fileSystems."/host-nix/nix" = {
      device = "hostnix";
      fsType = "virtiofs";
      neededForBoot = true;
      options = [
        "nofail"
        "ro"
      ];
    };

    # Zero-copy overlay store: the host store is the lower layer, this disk's
    # .rw-store the upper. The daemon owns the overlay URI (on its command
    # line, not nix.conf) so that an unprivileged `nix-daemon --stdio` proxies
    # instead of trying to open what it cannot write; all copied verbatim from
    # the builder guest, including the doubled %% that keeps systemd from
    # eating the percent-escapes.
    nix.settings = {
      experimental-features = [
        "local-overlay-store"
        "read-only-local-store"
      ];
      store = "daemon";
    };
    systemd.services.nix-daemon.serviceConfig.ExecStart = [
      ""
      "@${config.nix.package}/bin/nix-daemon nix-daemon --daemon --store ${
        lib.replaceStrings [ "%" ] [ "%%" ] overlayStoreUri
      }"
    ];
    systemd.services.nix-daemon.unitConfig.RequiresMountsFor = [
      "/host-nix/nix"
      "/"
    ];
    # The overlay itself is mounted by an explicit initrd service below rather
    # than by a fileSystems entry, and the reason is measured, not stylistic.
    # A neededForBoot fileSystems entry puts /nix/store in both fstabs: the
    # initrd mounts it at /sysroot/nix/store so the pivot can exec this
    # system's init out of it -- and then the root side mounts it AGAIN,
    # stacking a second overlay whose flags come out read-only. The builder
    # never meets this because it never pivots; here it made every store write
    # fail with EROFS. One mount, made once, by hand:
    boot.initrd.systemd.storePaths = [
      "${pkgs.util-linux}/bin/mount"
      "${pkgs.coreutils}/bin/mkdir"
    ];
    boot.initrd.systemd.services.nix-store-overlay = {
      description = "Mount /nix/store over the host store";
      # Ordered ahead of initrd.target so every store consumer -- notably
      # initrd-find-nixos-closure, whose RequiresMountsFor cannot see this
      # service, since it is not a .mount unit -- waits for it.
      requiredBy = [ "initrd.target" ];
      before = [
        "initrd.target"
        "initrd-find-nixos-closure.service"
        "shutdown.target"
      ];
      conflicts = [ "shutdown.target" ];
      after = [ "sysroot.mount" ];
      unitConfig = {
        DefaultDependencies = false;
        RequiresMountsFor = [
          "/sysroot"
          "/sysroot/host-nix/nix"
        ];
        ConditionPathExists = "!/sysroot/nix/store";
      };
      serviceConfig = {
        Type = "oneshot";
        # Output mirrored to the console -- which is a log file on the Mac --
        # because the initrd journal dies with the initrd, and a mount failure
        # here otherwise leaves nothing but "see systemctl status" behind.
        StandardOutput = "journal+console";
        StandardError = "journal+console";
        ExecStart = [
          "${pkgs.coreutils}/bin/mkdir -p -m 0755 /sysroot/nix/store /sysroot/nix/.rw-store/store /sysroot/nix/.rw-store/work"
          # nodev,nosuid stated here so stage 2's enforcement pass finds
          # nothing missing and skips its self-bind -- see
          # boot.nixStoreMountOpts below.
          "${pkgs.util-linux}/bin/mount -t overlay overlay -o lowerdir=/sysroot/host-nix/nix/store,upperdir=/sysroot/nix/.rw-store/store,workdir=/sysroot/nix/.rw-store/work,nodev,nosuid /sysroot/nix/store"
        ];
      };
    };

    # The authorized key arrives on its own read-only share rather than being
    # baked in, so changing who may log in stages a new file at start instead
    # of rebuilding this closure. Same shape as the builder guest.
    fileSystems."/var/keys" = {
      device = "keys";
      fsType = "virtiofs";
      options = [ "ro" ];
    };

    # x86_64 containers on this arm64 guest, through Rosetta's binfmt handler.
    # A Kubernetes node that can run amd64 images is worth the one device.
    virtualisation.rosetta.enable = true;

    # Long-lived machine, so clock discipline stays on -- the builder turns it
    # off because it lives for a minute, and a cluster's logs and certificates
    # care about time in ways a build never does.
    services.timesyncd.enable = true;

    # Journal on disk rather than in /run, so yesterday's failure is still
    # diagnosable today. Default is volatile, which suits a VM that ceases to
    # exist between runs; this one persists.
    services.journald.extraConfig = "Storage=persistent";

    # Stage 2 bind-mounts /nix/store onto itself to enforce these options, and
    # its default list includes `ro` -- store immutability policy that would
    # silently re-read-only the writable overlay above on every boot. Keep the
    # two options a store can honour anyway; drop immutability, which here is
    # false by construction: the upper layer is this machine's own disk.
    boot.nixStoreMountOpts = [ "nodev" "nosuid" ];

    services.openssh = {
      enable = true;
      settings.PasswordAuthentication = false;

      # Keys arrive over virtiofs, and Virtualization.framework does not pass
      # ownership through, so StrictModes would refuse them for everyone. The
      # share is read-only and written only by the host, which is the check
      # StrictModes exists to approximate. Same conclusion as the builder.
      settings.StrictModes = false;

      # One global file, consulted for every account: whatever the host staged
      # into the key share at start-up may log in as root. That is the account
      # the Mac's activation deploys through, and this VM is single-tenant on a
      # host-only NAT -- root here adds nothing a trusted user could not reach.
      authorizedKeysFiles = lib.mkForce [ "/var/keys/authorized_keys" ];

      # The fixed keypair nixpkgs ships for its builder VM, installed at the
      # default path sshd scans. Deterministic host key means the Mac pins it
      # in a known_hosts file and scripts can use StrictHostKeyChecking=yes
      # with no TOFU step. Same trick as the builder guest.
      hostKeys = lib.mkForce [ ];
    };
    environment.etc."ssh/ssh_host_ed25519_key" = {
      mode = "0600";
      source = "${modulesPath}/profiles/keys/ssh_host_ed25519_key";
    };
    environment.etc."ssh/ssh_host_ed25519_key.pub" = {
      mode = "0644";
      source = "${modulesPath}/profiles/keys/ssh_host_ed25519_key.pub";
    };

    # How the Mac finds this machine: mDNS, answered natively by
    # mDNSResponder on the host with nothing configured there. bootpd serves
    # no DNS, so DHCP alone resolves nothing.
    networking.hostName = "linuxvm";
    networking.useNetworkd = true;
    networking.useDHCP = false;
    systemd.network.networks."10-uplink" = {
      matchConfig.Name = "en*";
      networkConfig.DHCP = "ipv4";
      linkConfig.RequiredForOnline = "no";
    };

    # A firewall, because unlike the builder this machine lives a long time and
    # runs workloads that listen. Port 22 for management, 5353/udp so avahi's
    # announcements are heard. Everything else is opened deliberately, through
    # this module system, as workloads arrive.
    networking.firewall = {
      enable = true;
      allowedTCPPorts = [ 22 ];
      allowedUDPPorts = [ 5353 ];
    };
    services.avahi = {
      enable = true;
      publish = {
        enable = true;
        addresses = true;
        workstation = true;
      };
    };

    # A workload machine evaluates little and reads less documentation.
    documentation.enable = false;
    documentation.nixos.enable = false;

    # Small diagnostics that earn their place the first time a container or a
    # mount misbehaves.
    environment.systemPackages = with pkgs; [
      file
      htop
      lsof
    ];
  };
}
