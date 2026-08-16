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
  ...
}:
let
  cfg = config.nix.linux-vz-builder;

  # eval-config.nix rather than a flake's lib.nixosSystem, so this module needs
  # nothing but a path to nixpkgs and could be lifted into nix-darwin as it is.
  guest = import "${cfg.nixpkgs}/nixos/lib/eval-config.nix" {
    modules = [
      ./guest.nix
      {
        nixpkgs.hostPlatform = "aarch64-linux";
        virtualisation.linux-vz-builder = {
          inherit (cfg) hostStore debugAccess;
        };
      }
    ]
    ++ cfg.extraModules;
  };

  inherit (guest.config.system.build) kernel netbootRamdisk toplevel;

  # Where the public half of the builder key is staged for the guest. Only the
  # public half: /etc/nix holds the private key too, and the guest has no
  # business seeing that directory.
  keyDir = "/var/lib/vz-builder/keys";

  # What the running VM was started from, so activation can tell a stale one
  # from a current one. Holds the guest's toplevel and the vfkit pid.
  runningFile = "/var/lib/vz-builder/running";

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
      # Read at start-up rather than baked in, so this follows the machine it
      # runs on instead of pinning one Mac's core count into the repo.
      cpus=${if cfg.cores == null then "$(/usr/sbin/sysctl -n hw.ncpu)" else toString cfg.cores}

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
        hostStore=(--device "virtio-fs,sharedDir=/nix,mountTag=hostnix")
      ''}

      vfkit \
        --cpus "$cpus" \
        --memory ${toString cfg.memory} \
        --bootloader "linux,kernel=${kernel}/Image,initrd=${netbootRamdisk}/initrd,cmdline=\"console=hvc0 init=${toplevel}/init\"" \
        --device virtio-rng \
        --device "virtio-net,nat" \
        --device "virtio-fs,sharedDir=${keyDir},mountTag=keys" \
        "''${rosetta[@]}" \
        ${lib.optionalString (cfg.hostStore != "off") ''"''${hostStore[@]}" \''}
        --device "virtio-serial,logFilePath=/var/log/vz-builder.log" &
      vm=$!

      # Recorded for the activation check in ./default.nix, and cleared on the
      # way out so a dead VM never looks live.
      printf '%s\n%s\n' ${lib.escapeShellArg toplevel} "$vm" > ${lib.escapeShellArg runningFile}
      trap 'rm -f ${lib.escapeShellArg runningFile}' EXIT

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

      # First connection pays the boot; later ones find it already up. Polled
      # four times a second rather than once: a whole-second granularity adds
      # half a second on average to every cold build, which is real next to a
      # boot measured in single digits.
      for _ in $(seq 1 $(( ${toString cfg.bootTimeout} * 4 ))); do
        if socat -u OPEN:/dev/null TCP:${guestHost}:22,connect-timeout=1 2>/dev/null; then
          break
        fi
        sleep 0.25
      done

      exec socat STDIO TCP:${guestHost}:22
    '';
  };
in
{
  options.nix.linux-vz-builder = {
    enable = lib.mkEnableOption "a Linux builder running under Virtualization.framework";

    nixpkgs = lib.mkOption {
      type = lib.types.path;
      default = pkgs.path;
      defaultText = lib.literalExpression "pkgs.path";
      description = ''
        The nixpkgs used to build the guest. Defaults to the one this system is
        built from, which is usually what you want; point it elsewhere if the
        builder should track a different channel from its host.
      '';
    };

    extraModules = lib.mkOption {
      type = lib.types.listOf lib.types.deferredModule;
      default = [ ];
      example = lib.literalExpression ''[ { boot.binfmt.emulatedSystems = [ "riscv64-linux" ]; } ]'';
      description = "Extra NixOS modules to merge into the guest.";
    };

    cores = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = ''
        vCPUs given to the builder, or null for every core the host has.

        All of them is the default because this VM only exists while a build is
        running: there is no long-lived neighbour to starve, so holding cores
        back would just make builds slower for nothing. The count is read from
        `sysctl hw.ncpu` at start-up rather than fixed here.
      '';
    };

    maxJobs = lib.mkOption {
      type = lib.types.int;
      default = 4;
      description = ''
        Derivations Nix runs on the builder at once.

        An integer, necessarily: /etc/nix/machines parses this column with
        `string2Int<unsigned int>` and throws on anything else, so there is no
        `auto` to match the host's core count. Set it per machine.

        Separate from `cores`, which the guest sets to 0 -- Nix's sentinel for
        "every core there is", so each job may use the whole VM. The two
        oversubscribe on purpose: few builds parallelise well enough to
        saturate the machine alone.
      '';
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

    debugAccess = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Let the guest be logged into for profiling. See ./guest.nix -- it
        authorises a publicly-known key, so it is off by default and meant to
        be switched on for a session rather than left on.
      '';
    };

    hostStore = lib.mkOption {
      type = lib.types.enum [
        "off"
        "substituter"
        "overlay"
      ];
      default = "overlay";
      description = ''
        Whether and how to share this Mac's /nix/store into the builder. See
        ./guest.nix for what each value means.

        `overlay` is the default and is what you want. Inputs the Mac already
        has are read where they lie, so an x86_64-linux build that used to
        fetch its whole stdenv from cache.nixos.org now starts in under two
        seconds and copies nothing.

        Four things it needs, none of them obvious, all of them load-bearing:

        - the host store as the *only* lower layer. The guest's own closure was
          built on this Mac, so it is already in there -- netboot's squashfs is
          redundant rather than an obstacle, which matters because Nix requires
          exactly one lower dir equal to the lower store's realStoreDir.
        - `read-only-local-store`, a second experimental feature on top of
          `local-overlay-store`, because the lower store is on a read-only
          mount and Nix opens store databases read-write even to query them.
        - `check-mount=false`. Stage 1 mounts under /sysroot and the kernel
          goes on recording `lowerdir=/sysroot/...` after the pivot, so the
          check compares against a stale string and can never pass.
        - the store URI on the daemon's command line only, with `store =
          daemon` in nix.conf. See ./guest.nix -- this is the part that took
          longest to get right.

        `substituter` is the fallback if any of that regresses: inputs still
        come from this Mac rather than the network, but they are copied into
        the guest's tmpfs instead of referenced in place.
      '';
    };

    idleTimeout = lib.mkOption {
      type = lib.types.int;
      default = 60;
      description = ''
        Seconds without a connection before the VM shuts down.

        Short on purpose. The VM holds its whole memory footprint for as long
        as it lives -- the host cannot reclaim a guest's page cache -- and it
        boots again in a few seconds, so there is little to gain by lingering
        and a couple of GiB to lose.
      '';
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

    # Stop a VM that is running an older guest than the one just activated.
    #
    # Without this the change is not live until the VM next idles out, and it
    # is invisible: the builder answers, builds, and behaves exactly as before,
    # because it is still the previous generation. That cost real debugging
    # time -- two boot-time measurements of a networkd change were taken
    # against a VM that predated it, and read as confirmation that it worked.
    #
    # This does interrupt a build in flight, on purpose. The alternative is
    # serving results from a guest the configuration no longer describes.
    system.activationScripts.postActivation.text = ''
      running=${lib.escapeShellArg runningFile}
      if [ -e "$running" ]; then
        gen=$(head -1 "$running")
        pid=$(sed -n 2p "$running")
        if [ "$gen" != ${lib.escapeShellArg toplevel} ]; then
          echo "vz-builder: guest changed, stopping the stale VM (pid $pid)"
          kill "$pid" 2>/dev/null || true
          rm -f "$running"
        fi
      fi
    '';

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
        maxJobs = cfg.maxJobs;
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
