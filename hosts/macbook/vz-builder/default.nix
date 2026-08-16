# A Linux builder VM on Virtualization.framework, started on demand.
#
# Two differences from `nix.linux-builder`, which runs QEMU and stays up from
# boot to shutdown:
#
#  - Apple's hypervisor instead of QEMU, which is what makes Rosetta reachable.
#    Rosetta-for-Linux is a Virtualization.framework feature, so the QEMU
#    builder cannot have it at any price. This VM answers for x86_64-linux as
#    well as aarch64-linux.
#
#  - launchd socket activation, so nothing runs until a build needs it. That
#    matters more than it sounds: guest RAM is one anonymous mapping to the
#    host, and a guest's page cache is indistinguishable from its heap, so the
#    host cannot reclaim it. An idle VM ratchets its footprint up and never
#    gives it back. A VM that exits has given all of it back, and this one
#    boots in about seven seconds.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.local.vzBuilder;

  guest = inputs.nixpkgs.lib.nixosSystem {
    system = "aarch64-linux";
    modules = [
      ./guest.nix
      { vzBuilder.hostStore = cfg.hostStore; }
    ];
  };

  inherit (guest.config.system.build) kernel netbootRamdisk toplevel;

  # Where the public half of the builder key is staged for the guest. Only the
  # public half: /etc/nix holds the private key too, and the guest has no
  # business seeing that directory.
  keyDir = "/var/lib/vz-builder/keys";

  # The guest publishes this over mDNS and mDNSResponder answers it natively,
  # so nothing here has to discover an IP.
  guestHost = "${guest.config.networking.hostName}.local";

  runVm = pkgs.writeShellApplication {
    name = "vz-builder-vm";
    runtimeInputs = [
      pkgs.vfkit
      pkgs.coreutils
      pkgs.procps
    ];
    text = ''
      install -d -m 0755 ${lib.escapeShellArg keyDir}
      install -m 0444 /etc/nix/builder_ed25519.pub ${lib.escapeShellArg keyDir}/builder_ed25519.pub

      # Rosetta has to be present on the host; `softwareupdate --install-rosetta`
      # puts it there. Without it the VM still boots and still builds
      # aarch64-linux, it just cannot answer for x86_64-linux.
      rosetta=()
      if [ -d /Library/Apple/usr/libexec/oah ]; then
        rosetta=(--device "rosetta,mountTag=rosetta")
      else
        echo "vz-builder: Rosetta is not installed; x86_64-linux will not work" >&2
      fi

      ${lib.optionalString (cfg.hostStore != "off") ''
        # Read-only, and both halves: a store path that no database knows about
        # is invisible to Nix, so the store alone would buy nothing.
        hostStore=(
          --device "virtio-fs,sharedDir=/nix/store,mountTag=hoststore"
          --device "virtio-fs,sharedDir=/nix/var/nix/db,mountTag=hostdb"
        )
      ''}

      vfkit \
        --cpus ${toString cfg.cores} \
        --memory ${toString cfg.memory} \
        --bootloader "linux,kernel=${kernel}/Image,initrd=${netbootRamdisk}/initrd,cmdline=\"console=hvc0 init=${toplevel}/init\"" \
        --device virtio-rng \
        --device "virtio-net,nat" \
        --device "virtio-fs,sharedDir=${keyDir},mountTag=keys" \
        "''${rosetta[@]}" \
        ${lib.optionalString (cfg.hostStore != "off") ''"''${hostStore[@]}" \''}
        --device "virtio-serial,logFilePath=/var/log/vz-builder.log" &
      vm=$!

      # Idle shutdown. A connection is live exactly while its handler runs, so
      # counting handlers is an accurate idle test and needs nothing from the
      # guest. Without this the VM would outlive the build that started it and
      # keep holding the RAM this design exists to give back.
      idle=0
      while kill -0 $vm 2>/dev/null; do
        sleep 15
        if pgrep -f vz-builder-connect >/dev/null; then
          idle=0
        else
          idle=$((idle + 15))
          if [ "$idle" -ge ${toString cfg.idleTimeout} ]; then
            echo "vz-builder: idle for ${toString cfg.idleTimeout}s, shutting down" >&2
            kill $vm 2>/dev/null || true
            break
          fi
        fi
      done
      wait $vm 2>/dev/null || true
    '';
  };

  # launchd hands this an accepted connection on stdin/stdout. It brings the VM
  # up if it is not already, waits for the guest to answer, then gets out of
  # the way and just moves bytes.
  connect = pkgs.writeShellApplication {
    name = "vz-builder-connect";
    runtimeInputs = [
      pkgs.socat
      pkgs.coreutils
    ];
    text = ''
      /bin/launchctl kickstart system/org.nixos.vz-builder-vm 2>/dev/null || true

      # First connection pays the boot; later ones find it already up.
      for _ in $(seq 1 ${toString cfg.bootTimeout}); do
        if socat -u OPEN:/dev/null TCP:${guestHost}:22,connect-timeout=1 2>/dev/null; then
          break
        fi
        sleep 1
      done

      exec socat STDIO TCP:${guestHost}:22
    '';
  };
in
{
  options.local.vzBuilder = {
    enable = lib.mkEnableOption "the Virtualization.framework Linux builder";

    cores = lib.mkOption {
      type = lib.types.int;
      default = 6;
      description = "vCPUs given to the builder.";
    };

    memory = lib.mkOption {
      type = lib.types.int;
      default = 8192;
      description = ''
        Guest RAM in MiB. The guest store is a tmpfs, so this also bounds how
        large a single build can be -- there is no disk to spill to.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 31122;
      description = ''
        Loopback port launchd listens on. Connecting to it starts the VM.
        31022 belongs to `nix.linux-builder`, so this is deliberately not that.
      '';
    };

    hostStore = lib.mkOption {
      type = lib.types.enum [
        "off"
        "substituter"
        "overlay"
      ];
      default = "substituter";
      description = ''
        Whether and how to share this Mac's /nix/store into the builder. See
        ./guest.nix for what each value means.

        `overlay` is the better answer and is not the default. It uses Nix's
        experimental local-overlay-store, and it rests on two behaviours that
        were measured rather than documented: overlayfs accepts a virtiofs
        lower layer, and the host's live WAL database can be read over a
        read-only mount. The second is not a supported SQLite configuration --
        it works, which is not the same as being safe while the host daemon
        writes. `substituter` gives most of the benefit with none of that.
      '';
    };

    idleTimeout = lib.mkOption {
      type = lib.types.int;
      default = 600;
      description = "Seconds without a connection before the VM shuts down.";
    };

    bootTimeout = lib.mkOption {
      type = lib.types.int;
      default = 90;
      description = "Seconds to wait for a cold guest to answer on port 22.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Started by ./default.nix's connect handler, never at load. RunAtLoad and
    # KeepAlive would defeat the entire point.
    launchd.daemons.vz-builder-vm = {
      script = "exec ${lib.getExe runVm}";
      serviceConfig = {
        RunAtLoad = false;
        KeepAlive = false;
        StandardErrorPath = "/var/log/vz-builder-vm.log";
      };
    };

    launchd.daemons.vz-builder = {
      serviceConfig = {
        ProgramArguments = [ (lib.getExe connect) ];
        Sockets.Listener = {
          SockNodeName = "127.0.0.1";
          SockServiceName = toString cfg.port;
          SockFamily = "IPv4";
          SockProtocol = "TCP";
        };
        # Wait = false: launchd calls accept() itself and hands the connection
        # over stdin/stdout, so the handler is an ordinary shell script rather
        # than something that has to speak the launchd check-in API.
        inetdCompatibility.Wait = false;
        StandardErrorPath = "/var/log/vz-builder.log";
      };
    };

    environment.etc."ssh/ssh_config.d/101-vz-builder.conf".text = ''
      Host vz-builder
        User builder
        Hostname 127.0.0.1
        Port ${toString cfg.port}
        HostKeyAlias vz-builder
        IdentityFile /etc/nix/builder_ed25519
    '';

    nix.distributedBuilds = true;

    nix.buildMachines = [
      {
        hostName = "vz-builder";
        sshUser = "builder";
        sshKey = "/etc/nix/builder_ed25519";
        protocol = "ssh-ng";
        # The fixed key nixpkgs ships for its builder VM, which ./guest.nix
        # installs as the host key. nix-darwin hardcodes the same value for
        # `nix.linux-builder`; HostKeyAlias is what keeps the two entries
        # distinct despite sharing it.
        publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUpCV2N4Yi9CbGFxdDFhdU90RStGOFFVV3JVb3RpQzVxQkorVXVFV2RWQ2Igcm9vdEBuaXhvcwo=";
        systems = [
          "aarch64-linux"
          "x86_64-linux" # via Rosetta
        ];
        maxJobs = cfg.cores;
        speedFactor = 2; # native aarch64 under Apple's hypervisor
        # No kvm: this is a guest, and nothing nested is available to it.
        supportedFeatures = [
          "big-parallel"
          "benchmark"
        ];
      }
    ];

    # Let the builder fetch its own inputs instead of pushing every closure
    # over the wire to it.
    nix.settings.builders-use-substitutes = true;
  };
}
