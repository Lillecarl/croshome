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

  # The runner is the half that can move to nixpkgs: it knows nothing about
  # nix-darwin. See ./vm.nix.
  vm = import ./vm.nix { inherit lib pkgs cfg guest; };

  inherit (guest.config.system.build) toplevel;

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

    vfkit = lib.mkOption {
      type = lib.types.package;
      default = pkgs.vfkit;
      defaultText = lib.literalExpression "pkgs.vfkit";
      description = ''
        The vfkit that runs the VM.

        The default is this repo's overlay patch (../../../pkgs/vfkit-balloon.nix),
        which exposes the memory balloon over vfkit's REST API. Upstream vfkit
        lacks that endpoint, so the balloon is simply inert with a stock vfkit
        and nothing else changes.
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

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/vz-builder";
      description = ''
        Directory for the builder's host-side state: the SSH key share, the
        running-VM marker and the REST socket. Created at VM start.
      '';
    };

    imageDir = lib.mkOption {
      type = lib.types.str;
      default = "/nix/var";
      description = ''
        Directory for the ephemeral store and swap images.

        Only a directory of image files, so it need not itself be
        case-sensitive -- the ext4 inside each image is. It defaults under /nix
        because that volume is already known writable and large, not for any
        property of the filesystem.
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

    builderKey = lib.mkOption {
      type = lib.types.str;
      default = "/etc/nix/builder_ed25519";
      description = ''
        Private key the host uses to log into the guest; its public half is
        `${cfg.builderKey}.pub`.

        Defaults to the path nix-darwin's own builders use, so a machine that
        already runs one shares this key rather than keeping a second. It is
        created on activation when either half is missing, so the module does
        not depend on another builder having run first.
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
    environment.systemPackages = [ vm.vzrun ];

    # Started by ./vm.nix's connect handler, never at load. RunAtLoad and
    # KeepAlive would defeat the entire point.
    launchd.daemons.vz-builder-vm = {
      script = "exec ${lib.getExe vm.runVm}";
      serviceConfig = {
        RunAtLoad = false;
        KeepAlive = false;
        StandardErrorPath = "/var/log/vz-builder-vm.log";
      };
    };

    launchd.daemons.vz-builder = {
      serviceConfig = {
        ProgramArguments = [ (lib.getExe vm.connect) ];
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

    # Create the builder keypair when either half is missing, rather than
    # assume another builder created it. Same path and group (nixbld) that
    # nix-darwin's own builder installer uses, so a machine running both shares
    # one key instead of each fighting for the path. First, because runVm, the
    # machines file and ssh all expect the pair to exist.
    system.activationScripts.preActivation.text = ''
      builderKey=${lib.escapeShellArg cfg.builderKey}
      if [ ! -e "$builderKey" ] || [ ! -e "$builderKey.pub" ]; then
        rm -f "$builderKey" "$builderKey.pub"
        install -d -m 0755 "$(dirname "$builderKey")"
        ${lib.getExe' pkgs.openssh "ssh-keygen"} -q -t ed25519 -N "" -C builder@vz-builder -f "$builderKey"
        chgrp nixbld "$builderKey" "$builderKey.pub"
        chmod 0600 "$builderKey"
        chmod 0644 "$builderKey.pub"
      fi
    ''
    # Refuse to activate, before any other activation step has run, when /nix
    # cannot support the configured store-sharing mode. preActivation is
    # nix-darwin's earliest hook (see modules/system/activation-scripts.nix),
    # so the switch stops before it mutates anything.
    #
    # Only `overlay` shares the host store's paths directly into the guest, and
    # it needs a case-sensitive /nix to do so: on a case-insensitive store Nix
    # mangles colliding names (`use-case-hack`) and the guest reads the mangled
    # names rather than the real ones. `substituter` and `off` copy paths into
    # the guest instead, so the mangling never crosses the boundary and they
    # have no such requirement.
    #
    # A filesystem property, not a configuration one, so it is probed here
    # rather than asserted during evaluation.
    + lib.optionalString (cfg.hostStore == "overlay") ''
      caseprobe=$(mktemp -d /nix/.vz-case-check-XXXXXX)
      touch "$caseprobe/a"
      if [ -e "$caseprobe/A" ]; then
        rm -rf "$caseprobe"
        echo "nix.linux-vz-builder: /nix is on a case-INSENSITIVE filesystem." >&2
        echo "  hostStore = \"overlay\" cannot work there: Nix mangles colliding" >&2
        echo "  store names and the guest reads the mangled ones." >&2
        echo "" >&2
        echo "  Do one of:" >&2
        echo "    1. put /nix on a case-sensitive APFS volume, or" >&2
        echo "    2. set nix.linux-vz-builder.hostStore = \"substituter\", which" >&2
        echo "       copies inputs from this Mac instead of referencing them." >&2
        exit 1
      fi
      rm -rf "$caseprobe"
    '';

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
      running=${lib.escapeShellArg vm.runningFile}
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
        IdentityFile ${cfg.builderKey}
    '';

    nix.distributedBuilds = true;

    nix.buildMachines = [
      {
        hostName = "vz-builder";
        sshUser = "builder";
        sshKey = cfg.builderKey;
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
        # kvm: the vfkit invocation above passes `--nested`, and ./guest.nix
        # loads the kvm module, so a build that asks for it gets real
        # hardware-accelerated nested virtualization instead of the
        # scheduler refusing to send it here at all.
        supportedFeatures = [
          "big-parallel"
          "benchmark"
          "kvm"
          "nixos-test"
        ];
      }
    ];

    # Let the builder fetch its own inputs instead of pushing every closure
    # over the wire to it.
    nix.settings.builders-use-substitutes = true;
  };
}
