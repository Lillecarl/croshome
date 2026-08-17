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

        # The host's flake registry, verbatim, so the two cannot drift.
        #
        # Copying an *evaluated* submodule back in as a definition is usually a
        # mistake, and it is safe here for a specific reason: nix-flakes.nix
        # defines `to` as `mkIf (flake != null) (mkDefault {...})`, and
        # nix-darwin's module matches. mkDefault is priority 1000, so the
        # explicit `to` we hand over at priority 100 overrides it instead of
        # colliding with it. Verified by evaluation before relying on it.
        #
        # Doing it this way rather than rebuilding the entry from a path also
        # keeps narHash, rev and lastModified, so the guest's registry is
        # locked exactly as the host's is.
        nix.registry = config.nix.registry;

        # NIX_PATH verbatim as well, which takes replicating what it names.
        # The host spells it `nixpkgs=/etc/nixpkgs`, and /etc in the guest is
        # the guest's own, so the entry would dangle -- confirmed by looking:
        # the guest had no /etc/nixpkgs at all. Giving the guest that same
        # entry, pointing at the same store path the host's symlink resolves
        # to, makes the host's own spelling true in here.
        #
        # The limit of this, for anyone lifting the module: an entry naming a
        # host path that is not `environment.etc.nixpkgs` still dangles. This
        # replicates the one indirection nix-darwin and NixOS share, not
        # arbitrary host layout.
        nix.nixPath = config.nix.nixPath;
        # `source` alone, not the whole entry. nix-darwin's environment.etc
        # submodule has `knownSha256Hashes`, which NixOS's does not, so handing
        # the evaluated entry over fails with "option does not exist". The two
        # module systems agree on what an /etc entry means, not on its fields.
        #
        # nix.registry above survives the same treatment only because those two
        # submodules happen to match field for field. Copying evaluated config
        # between darwin and NixOS is safe per option, never in general.
        environment.etc = lib.optionalAttrs (config.environment.etc ? nixpkgs) {
          nixpkgs.source = config.environment.etc.nixpkgs.source;
        };
        # Experimental features from the host, so one list governs both. A
        # derivation that needs `dynamic-derivations` to evaluate on this Mac
        # needs it to build in here as well, and the guest had no way to learn
        # that. `nix.settings.experimental-features` is a list, and NixOS
        # merges list definitions by concatenation, so this adds to what
        # ./guest.nix states for its own store topology rather than replacing
        # it. Duplicates in that list are harmless.
        #
        # This is inheritance, not replication: the host list is the only place
        # a feature is named for both machines.
        nix.settings.experimental-features = config.nix.settings.experimental-features;

        virtualisation.linux-vz-builder = {
          inherit (cfg) hostStore debugAccess;
          swap = cfg.swapSize > 0;
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

  # Build outputs, scratch and swap, on real disks rather than in RAM.
  #
  # Build scratch used to be a virtiofs share of a host directory. That put it
  # on the SSD but gave it the host's clock, and the guest runs about 70ms
  # behind macOS -- so files came back with an mtime in the guest's future and
  # meson reported clock skew. It lives on the guest's own ext4 now. See
  # ./guest.nix.
  #
  # It also retires a constraint: the share had to sit under /nix because every
  # macOS-managed temp directory is on the case-insensitive boot volume, and a
  # build directory where `foo` and `FOO` collide breaks the derivations a
  # case-sensitive store exists to support. A guest filesystem has no such
  # problem. The images below stay under /nix anyway, since that is the volume
  # the activation check already proves is case-sensitive.
  #
  # netboot puts the overlay's upper layer on a tmpfs, so every build *output*
  # was charged to guest RAM and capped at half of it -- 3.9 GiB of the 8. A
  # build large enough to exceed that died, which is what these two images fix.
  #
  # Recreated on every start, like buildScratch, so they are ephemeral in the
  # same sense. That costs nothing: `truncate` writes no data, the guest's
  # mkfs.ext4 leaves the image sparse, and it is the same /nix volume the
  # activation check already proves is case-sensitive.
  storeDisk = "/nix/var/vz-store.img";
  swapDisk = "/nix/var/vz-swap.img";

  # vfkit's REST endpoint, which ../../../pkgs/vfkit-balloon.nix extends with
  # /vm/memory-balloon. A unix socket rather than a loopback port: the balloon
  # can shrink a running guest and /vm/state can stop it, and a socket is
  # reachable only by something that can open this path. 30 bytes, comfortably
  # inside the 104-byte limit macOS puts on a unix socket path.
  restSocket = "/var/lib/vz-builder/rest.sock";

  # The guest publishes this over mDNS and mDNSResponder answers it natively,
  # so nothing here has to discover an IP.
  guestHost = "${guest.config.networking.hostName}.local";

  # Delivered over the key share at start-up, like the builder key beside it,
  # so changing who may log in does not rebuild the guest.
  authorizedKeysFile = pkgs.writeText "vz-builder-authorized-keys" (
    lib.concatLines cfg.authorizedKeys
  );

  # `vzrun` verifies the guest against the public half of the fixed key
  # ./guest.nix installs, taken from the same nixpkgs the guest is built from.
  # So there is no first-use prompt, and no entry written into your own
  # known_hosts for a machine that is rebuilt every few minutes.
  knownHosts = pkgs.writeText "vz-builder-known-hosts" ''
    vz-builder ${builtins.readFile "${cfg.nixpkgs}/nixos/modules/profiles/keys/ssh_host_ed25519_key.pub"}
  '';

  # Run a Linux command in the builder, for the Linux-only things a Nix build
  # cannot do: anything that wants a network, a real /proc, a mount namespace,
  # or just a shell.
  #
  # Nothing about it is special-cased on the host side. It connects to the same
  # port a distributed build does, so it starts the VM the same way, and the
  # idle watchdog counts its connection the same way -- an open session holds
  # the VM up and closing it starts the clock.
  vzrun = pkgs.writeShellApplication {
    name = "vzrun";
    runtimeInputs = [
      pkgs.openssh
      pkgs.coreutils # `id`, for the multiplexing socket path
    ];
    text = ''
      user=builder
      if [ "''${1-}" = "--root" ]; then
        user=root
        shift
      fi

      opts=(
        -p ${toString cfg.port}
        -l "$user"
        -o HostKeyAlias=vz-builder
        -o UserKnownHostsFile=${knownHosts}
        -o StrictHostKeyChecking=yes
        # Multiplexing, because this is meant to be called in a loop: a warm VM
        # answers a fresh handshake in about 150ms and a reused one in about
        # 20ms. ControlPersist stays well under idleTimeout
        # (${toString cfg.idleTimeout}s) so a forgotten master cannot pin the VM
        # up. The socket goes in /tmp because a macOS unix socket path cannot
        # exceed 104 bytes and %C alone is 64 of them.
        -o ControlMaster=auto
        -o "ControlPath=/tmp/vzrun-$(id -u)-%C"
        -o ControlPersist=30
      )

      if [ -t 0 ] && [ -t 1 ]; then
        opts+=(-t)
      else
        opts+=(-T)
      fi

      # Start in the same directory when the guest has one by that name. It
      # often does, and that is the point: /nix/store in the guest is this
      # Mac's store through the overlay, so a store path you are standing in
      # here is the same path there. `nix build` something for Linux, then run
      # ./result/bin/x under vzrun. Otherwise fall back to /scratch, which is
      # on the guest's disk and writable by anyone -- unlike Nix's build
      # directory, which is root-owned and was where this used to land.
      cd_to="cd $(printf '%q' "$PWD") 2>/dev/null || cd /scratch"

      if [ "$#" -eq 0 ]; then
        remote="$cd_to; exec \"\$SHELL\""
      else
        remote="$cd_to; exec $(printf '%q ' "$@")"
      fi

      # Quoted twice for two parses: sshd hands the string to the remote login
      # shell, which then hands the script to `bash -l`. The login shell is
      # what puts a usable PATH in front of the command.
      exec ssh "''${opts[@]}" 127.0.0.1 -- bash -lc "$(printf '%q' "$remote")"
    '';
  };

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

      # Sparse and fresh every start. A 128 GiB store disk occupies about 6 MiB
      # once formatted, and the guest's mkfs.ext4 takes ~95ms at any size
      # between 32 and 256 GiB -- measured, because `fileSystems.autoFormat`
      # gives no way to pass mkfs options and a filesystem that wrote its inode
      # tables eagerly would have cost seconds on a seven-second boot.
      #
      # Order matters below: the store disk is added first, so it is /dev/vda
      # in the guest and swap is /dev/vdb.
      rm -f ${lib.escapeShellArg restSocket}
      rm -f ${lib.escapeShellArg storeDisk} ${lib.escapeShellArg swapDisk}
      truncate -s ${toString cfg.diskSize}M ${lib.escapeShellArg storeDisk}
      disks=(--device "virtio-blk,path=${storeDisk}")
      ${lib.optionalString (cfg.swapSize > 0) ''
        truncate -s ${toString cfg.swapSize}M ${lib.escapeShellArg swapDisk}
        disks+=(--device "virtio-blk,path=${swapDisk}")
      ''}

      install -d -m 0755 ${lib.escapeShellArg keyDir}
      install -m 0444 /etc/nix/builder_ed25519.pub ${lib.escapeShellArg keyDir}/builder_ed25519.pub
      install -m 0444 ${authorizedKeysFile} ${lib.escapeShellArg keyDir}/authorized_keys

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
        --device virtio-balloon \
        --device "virtio-net,nat" \
        --device "virtio-fs,sharedDir=${keyDir},mountTag=keys" \
        "''${disks[@]}" \
        "''${rosetta[@]}" \
        ${lib.optionalString (cfg.hostStore != "off") ''"''${hostStore[@]}" \''}
        --restful-uri "unix://${restSocket}" \
        --device "virtio-serial,logFilePath=/var/log/vz-builder.log" &
      vm=$!

      # vfkit creates the socket under root's umask, so 0755 -- and connecting
      # to a unix socket needs *write* permission, which leaves it root-only.
      # Opened up so an ordinary session can read the balloon without sudo. It
      # grants no privilege that reaching the builder on ${toString cfg.port}
      # does not already grant, that being a shell as a trusted Nix user.
      (
        for _ in $(seq 1 100); do
          if [ -S ${lib.escapeShellArg restSocket} ]; then
            chmod 0666 ${lib.escapeShellArg restSocket}
            break
          fi
          sleep 0.1
        done
      ) &

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
            # Plain SIGTERM, deliberately, and it is already the ACPI-request-
            # then-hard-kill sequence this looks like it is missing: vfkit's
            # own signal handler (cmd/vfkit/main.go's shutdownFunc) answers
            # SIGTERM by calling the guest's requestStop, waiting up to 5s for
            # VirtualMachineStateStopped, and force-`Stop()`ing only if that
            # does not land. Nothing here needs to reimplement that.
            #
            # It cannot land on this guest, though, and that is a fact about
            # this VM, not a bug in vfkit. Virtualization.framework's
            # requestStop is an ACPI power-button event, and ACPI tables are
            # an EFI-boot thing; this guest boots straight from a kernel and
            # initrd (the --bootloader "linux,..." line in runVm below, with
            # no ACPI in guest.nix's kernel modules to match), so there is
            # nothing on the guest side to receive the request. `stopped`
            # comes back false, the 5s wait always elapses, and every idle
            # shutdown is a hard stop in practice -- indistinguishable from
            # pulling power.
            #
            # That is why systemd inside the guest never runs its shutdown
            # targets and avahi never sends an mDNS goodbye for
            # ${guestHost}.local, which is what let a stale registration
            # squat that name across a restart and hang every `vzrun` dialing
            # it -- ../default.nix's `connect` timeout exists to bound
            # exactly that failure rather than assume it cannot recur. Fixing
            # it at the source would mean booting this guest through EFI, a
            # bigger change than this comment. Reported as Lillecarl/
            # nanopynix's pynixd session hitting a `vzrun` hang, 2026-08-17.
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
      #
      # Each probe is wrapped in `timeout`, not just socat's own
      # connect-timeout=1. That option only bounds the connect() call; a name
      # that will never resolve blocks inside getaddrinfo before socat's own
      # alarm gets a chance to matter, and connect-timeout does not cover it.
      # Measured directly: with a stale mDNS registration squatting
      # ${guestHost} (see ../default.nix's runVm for why that happens), a
      # single probe hung for minutes, not the 1s the option promised.
      # `timeout` kills the whole process by wall clock regardless of which
      # syscall it is stuck in, which is the only bound that held.
      #
      # A wall-clock deadline (`$SECONDS`) rather than a fixed iteration
      # count, for the same reason: a fixed count of assumed-fast iterations
      # only bounds the total wait if every iteration is fast, which is
      # exactly what a hung probe disproves.
      ready=0
      deadline=$(( SECONDS + ${toString cfg.bootTimeout} ))
      while [ "$SECONDS" -lt "$deadline" ]; do
        if timeout 1 socat -u OPEN:/dev/null TCP:${guestHost}:22,connect-timeout=1 2>/dev/null; then
          ready=1
          break
        fi
        sleep 0.25
      done

      # Fail loudly here rather than fall through to the unbounded connect
      # below. Without this, exhausting the loop above and still trying the
      # real proxy turns "the guest never answered" into the exact hang this
      # whole probe loop exists to prevent -- which is what happened before
      # this check existed: a name that never resolves left `vzrun` blocked
      # indefinitely, and every such call leaked one stuck process here,
      # which in turn kept the idle watchdog in runVm from ever seeing this
      # VM as idle. Reported as Lillecarl/nanopynix's pynixd session hitting
      # a `vzrun` hang, 2026-08-17.
      if [ "$ready" -ne 1 ]; then
        echo "vz-builder-connect: ${guestHost}:22 did not answer within ${toString cfg.bootTimeout}s" >&2
        exit 1
      fi

      # Deliberately not `exec socat`. The idle watchdog in runVm above finds a
      # live connection with `pgrep -f vz-builder-connect`, and exec replaces
      # this process image, so the name it greps for disappears the instant the
      # handler starts moving bytes. Every open connection then looked idle and
      # the VM shut down under running builds, which surfaces as "Nix daemon
      # disconnected unexpectedly (maybe it crashed?)" -- a message that points
      # at the guest and not at the host that killed it. Keeping the wrapper
      # process alive costs one shell per open connection and makes the
      # watchdog's "counting handlers" comment true.
      #
      # connect-timeout=5 here too, purely as a backstop: the probe loop above
      # already proved ${guestHost} answers, so this should resolve from cache
      # and connect at once. If it does not, this bounds the wait instead of
      # repeating the unbounded hang the probe loop was added to prevent.
      socat STDIO TCP:${guestHost}:22,connect-timeout=5
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
        Guest RAM in MiB.

        Virtualization.framework backs guest memory lazily, so this is a
        ceiling rather than a reservation -- but it is a ceiling the host never
        gets back below. A guest frees memory internally and the host keeps it:
        measured, a guest that released 3 GiB and dropped its caches returned
        244 MiB to macOS. The VM exiting is what returns the rest, which is why
        `idleTimeout` is short.
      '';
    };

    diskSize = lib.mkOption {
      type = lib.types.int;
      default = 131072; # 128 GiB
      description = ''
        Size in MiB of the ephemeral disk holding build outputs and scratch.

        This is the store's writable layer, which netboot would otherwise put
        on a tmpfs -- charging every build output to guest RAM and capping it
        at half of `memory`. Builds larger than that died. Nix's build
        directory sits here too, so the two share the space.

        It only ever has to hold work in flight, which is why this is not
        larger. A build started from the Mac has its result copied back when
        it finishes, so the next VM start sees that path in the lower layer
        and the writable layer begins empty again.

        Generous by default because it costs almost nothing. The image is
        sparse and recreated on each start, so it occupies about 6 MiB until
        the guest writes to it, and the guest's mkfs takes ~95ms at any size
        from 32 to 256 GiB. Size it against free space on the /nix volume,
        which is the real limit.
      '';
    };

    swapSize = lib.mkOption {
      type = lib.types.int;
      default = cfg.memory * 2;
      defaultText = lib.literalExpression "memory * 2";
      description = ''
        Size in MiB of the ephemeral swap disk, or 0 for no swap.

        Twice `memory`, and computed from it: this was a fixed 16384, which
        held the stated ratio only while `memory` kept its own default. The
        image is sparse and recreated on each start, so unused swap costs
        nothing but the header mkswap writes.

        A second disk rather than a swapfile: NixOS builds a swapfile with
        `dd`, which would write the whole thing on every boot, while `mkswap`
        on a raw device writes only a header.

        This does not give memory back to the host -- nothing does, short of
        the VM exiting. What it buys is that a build spiking past `memory` is
        slow instead of OOM-killed, and that the root tmpfs becomes evictable,
        since tmpfs pages are swap-backed.
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

    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = lib.literalExpression ''[ "ssh-ed25519 AAAAC3Nz... you@mac" ]'';
      description = ''
        Public keys that may log into the guest, which is what `vzrun` needs.

        `vzrun` runs a command in the builder, for the Linux-only work a build
        sandbox cannot do -- something that wants a network, a real /proc, a
        mount namespace, or a shell. Without a key here the command is
        installed but every call is refused: the builder key in /etc/nix is
        root-owned and mode 0600, so it is not an answer for an ordinary user.

        The keys travel over the same virtiofs share as the builder key, so
        changing this list does not rebuild the guest.

        Note that ./guest.nix lists the key files globally rather than per
        user, so a key here logs in as `root` as well as `builder`. That is
        `vzrun --root`, and it is deliberate: the guest is disposable, it is
        reachable only from this Mac, and `builder` is a trusted Nix user
        already -- it can run arbitrary code here by submitting a derivation.
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
    environment.systemPackages = [ vzrun ];

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
      ${lib.optionalString (cfg.hostStore == "overlay") ''
        # /nix has to be case-sensitive for the overlay store to mean anything.
        # On a case-insensitive store Nix mangles colliding names
        # (`use-case-hack`), and a guest reading those paths through the
        # overlay sees the mangled names rather than the real ones. Checked
        # here rather than asserted during evaluation, because it is a property
        # of the filesystem and not of the configuration.
        caseprobe=$(mktemp -d /nix/.vz-case-check-XXXXXX)
        touch "$caseprobe/a"
        if [ -e "$caseprobe/A" ]; then
          rm -rf "$caseprobe"
          echo "nix.linux-vz-builder: /nix is on a case-INSENSITIVE filesystem." >&2
          echo "  hostStore = \"overlay\" cannot work there: Nix mangles colliding" >&2
          echo "  store names and the guest reads the mangled ones. Put /nix on a" >&2
          echo "  case-sensitive volume, or set hostStore to \"substituter\"." >&2
          exit 1
        fi
        rm -rf "$caseprobe"
      ''}
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
