# The Linux builder guest, as a NixOS system.
#
# There is no disk. netboot.nix puts the store in a squashfs inside the initrd
# and overlays a tmpfs on it, so the whole machine is a kernel plus an initrd
# and the upper layer lives in RAM. That is affordable only because the host
# store is mounted alongside it: the guest starts with every path this Mac has
# already built or fetched, so the upper layer only ever holds what is new.
{
  modulesPath,
  config,
  lib,
  ...
}:
let
  cfg = config.vzBuilder;
  sharingHostStore = cfg.hostStore != "off";

  # check-mount=false is not papering over a broken mount. Nix compares
  # /proc/self/mounts against the lower store's realStoreDir, and stage 1
  # mounts everything under /sysroot before pivoting, so the kernel goes on
  # recording `lowerdir=/sysroot/host-nix/nix/store` long after /sysroot is
  # gone. The layering is what Nix wants; only the string it compares is stale,
  # and no ordering fixes that while /nix/store must exist before stage 2.
  overlayStoreUri = lib.concatStringsSep "" [
    "local-overlay://"
    "?lower-store=/host-nix%3Fread-only=true"
    "&upper-layer=/nix/.rw-store/store"
    "&check-mount=false"
  ];
in
{
  imports = [ "${modulesPath}/installer/netboot/netboot.nix" ];

  options.vzBuilder.hostStore = lib.mkOption {
    type = lib.types.enum [
      "off"
      "substituter"
      "overlay"
    ];
    default = "substituter";
    description = ''
      How the guest uses the host's /nix/store, which is mounted read-only at
      /host-nix together with the host's Nix database.

      - `off`: not mounted. Every input comes over the network or the wire.
      - `substituter`: the host store is a trusted substituter. Inputs are
        copied from it instead of cache.nixos.org -- no network and no
        signature round trip, but the bytes still land in the tmpfs upper
        layer.
      - `overlay`: a local-overlay store. The host store becomes the lower
        layer and nothing is copied at all, so RAM holds only new outputs.
        Experimental in Nix; see ./default.nix for the caveats.
    '';
  };

  config = lib.mkMerge [
    {
      system.stateVersion = "26.11";

      boot.kernelParams = [
        "console=hvc0" # vfkit's virtio-serial
        "systemd.log_level=warning"
      ];

      boot.initrd.availableKernelModules = [ "virtiofs" ];
      boot.kernelModules = [
        "virtiofs"
        "overlay"
      ];

      # x86_64-linux through Rosetta. The module mounts the virtiofs share the
      # host exposes, registers the binfmt handler with Apple's documented
      # flags, and adds x86_64-linux to extra-platforms -- which is what lets
      # one VM answer for both Linux systems.
      virtualisation.rosetta.enable = true;

      # The authorized key arrives on its own share rather than being baked in,
      # so the guest image stays generic and cacheable instead of being rebuilt
      # per machine. ./default.nix copies only the public half into it.
      fileSystems."/var/keys" = {
        device = "keys";
        fsType = "virtiofs";
        options = [ "ro" ];
      };

      # Socket activation, on TCP. systemd accepts any SOCK_STREAM so vsock
      # would work identically, but vsock needs a ProxyCommand in root's ssh
      # config and the nix-daemon is what dials out. Over the NAT interface no
      # privileged host configuration is required at all.
      services.openssh = {
        enable = true;
        startWhenNeeded = true;
        settings.PasswordAuthentication = false;
        authorizedKeysFiles = lib.mkForce [ "/var/keys/builder_ed25519.pub" ];
      };

      # The fixed keypair nixpkgs ships for its own builder VM. nix-darwin
      # hardcodes the matching public half as `publicHostKey`, so reusing it
      # means the host verifies this VM with a value it already trusts.
      environment.etc."ssh/ssh_host_ed25519_key" = {
        mode = "0600";
        source = "${modulesPath}/profiles/keys/ssh_host_ed25519_key";
      };
      environment.etc."ssh/ssh_host_ed25519_key.pub" = {
        mode = "0644";
        source = "${modulesPath}/profiles/keys/ssh_host_ed25519_key.pub";
      };

      users.users.builder = {
        isNormalUser = true;
        group = "builder";
      };
      users.groups.builder = { };

      # How the host finds this machine. macOS bootpd records the DHCP hostname
      # in /var/db/dhcpd_leases but serves no DNS, so DHCP alone resolves
      # nothing. mDNS does: mDNSResponder answers <hostName>.local natively,
      # with nothing configured on the host side.
      networking.hostName = "vzbuilder";
      networking.useDHCP = true;
      services.avahi = {
        enable = true;
        publish = {
          enable = true;
          addresses = true;
          workstation = true;
        };
      };

      nix.settings = {
        trusted-users = [ "builder" ];
        experimental-features = [
          "nix-command"
          "flakes"
        ];
        # Two different knobs, both set to "use everything", because this VM
        # exists only while a build runs and has nothing to hold capacity back
        # for.
        #
        # max-jobs is how many jobs this machine builds in parallel, and it
        # takes `auto` -- the number of CPUs. (The maxJobs column in the host's
        # /etc/nix/machines is a different field, dispatch rather than
        # scheduling, and takes an integer only.)
        max-jobs = "auto";
        # cores is how many CPUs each individual job gets. 0 is its sentinel
        # for "all of them": the builder passes NIX_BUILD_CORES = buildCores,
        # falling back to getDefaultCores() when that is 0.
        cores = 0;
      };

      # A builder evaluates nothing, so it needs no docs.
      documentation.enable = false;
      documentation.nixos.enable = false;
      services.getty.autologinUser = "root";
    }

    # The host store and the host's Nix database. Both are needed: a path on
    # disk that no database knows about is invisible to Nix.
    (lib.mkIf sharingHostStore {
      fileSystems."/host-nix/nix/store" = {
        device = "hoststore";
        fsType = "virtiofs";
        options = [
          "nofail"
          "ro"
        ];
      };
      fileSystems."/host-nix/nix/var/nix/db" = {
        device = "hostdb";
        fsType = "virtiofs";
        options = [
          "nofail"
          "ro"
        ];
      };
    })

    (lib.mkIf (cfg.hostStore == "substituter") {
      # `trusted=1` because nothing in the host store is signed for this guest.
      # It is the same store the build is for, reached over a read-only mount,
      # so there is no third party whose signature would mean anything.
      nix.settings.extra-substituters = [ "local?root=/host-nix&trusted=1" ];
    })

    # Zero-copy: the host store *is* the lower layer, so an input already on
    # this Mac is referenced where it lies instead of being copied into the
    # guest's RAM.
    #
    # The database mount above is required for this, not an optimisation.
    # LocalOverlayStore does `openStore(lowerStoreUri)`, casts the result to a
    # LocalFSStore and queries it directly -- `lowerStore->queryRealisation`,
    # `queryPathInfoUncached`. It reads the lower store through a real store
    # object rather than through the overlay filesystem, so that store's own
    # SQLite database has to be present.
    #
    # Nix then checks the mount against /proc/self/mounts and requires exactly
    # one lower layer, equal to the lower store's realStoreDir:
    #
    #     auto expectedLowerDir = lowerStore->config.realStoreDir.get();
    #     checkOption("lowerdir", expectedLowerDir)
    #
    # That is why netboot's squashfs is dropped from the layering here rather
    # than kept alongside: two lowers fail the check. Nothing is lost by
    # dropping it. This guest is built on the host, so its own closure is
    # already in the host store -- the lower layer contains the very system
    # that is booting from it, which is what makes one layer sufficient.
    (lib.mkIf (cfg.hostStore == "overlay") {
      nix.settings = {
        experimental-features = [
          "local-overlay-store"
          # `read-only=true` below is gated behind its own feature, separate
          # from local-overlay-store.
          "read-only-local-store"
        ];

        # `read-only=true` on the lower store is required, not tuning. Nix
        # opens a store's database read-write even to query it, which fails
        # outright on a read-only mount; the flag drops locking and opens
        # SQLite with `immutable` instead.
        #
        # That is also the sharp edge of this whole mode. `immutable` promises
        # SQLite the file will not change, and the host's daemon writes to it
        # whenever anything builds on the Mac. It is what makes the live WAL
        # database readable at all, and it is why a stale or inconsistent read
        # is possible in principle. Switch hostStore to "substituter" if this
        # ever misbehaves.
        #
        # `%3F` is a literal `?`: the value is itself a store URI, and it has
        # to survive being a query parameter of the outer one. decodeQuery
        # percent-decodes it before openStore parses it.
        # NOTE: the store URI itself is deliberately *not* set here. See
        # systemd.services.nix-daemon below.
      };

      # The overlay store belongs to the daemon, not to every client, so it is
      # set in the daemon's environment rather than as a global `store` in
      # nix.conf.
      #
      # ssh-ng runs `nix-daemon --stdio` as the unprivileged `builder` user. A
      # global setting makes that process try to open the overlay store itself
      # -- writing the upper layer, taking locks -- which it has no permission
      # to do, and the connection dies with "Nix daemon disconnected
      # unexpectedly". Left unset, it resolves `auto`, finds it is not root,
      # and proxies to the daemon, which is the intended path.
      # The daemon serves the overlay store, set the ordinary way in nix.conf.
      # Passing --store on nix-daemon's command line instead does not work: the
      # legacy entry point rejects it and the daemon never starts, leaving
      # clients with "cannot connect to socket".
      nix.settings.store = overlayStoreUri;

      # ...and the ssh session must not try to open that store itself.
      # ssh-ng runs `nix-daemon --stdio` as the unprivileged `builder` user. It
      # resolves the same nix.conf, tries to open the overlay store directly --
      # writing the upper layer, taking locks -- has no permission, and the
      # connection dies as "Nix daemon disconnected unexpectedly".
      #
      # NIX_REMOTE=daemon sends it to the daemon instead, which is the whole
      # point of it being a daemon. sshd's SetEnv reaches non-interactive
      # commands, which /etc/profile would not.
      services.openssh.extraConfig = "SetEnv NIX_REMOTE=daemon";

      # neededForBoot on both halves, and for different reasons.
      #
      # The store: stage 1 has to mount it before it can overlay /nix/store,
      # and /nix/store is where the init it is about to exec lives.
      #
      # The database: nix-daemon opens the lower store once, at start-up. If
      # the mount is not there yet it opens an empty one and never revisits the
      # decision -- the overlay is mounted, files are visible, and Nix still
      # believes every lower path is invalid, so it refetches the whole world
      # from the network. That failure is silent, which is what makes it worth
      # a comment. RequiresMountsFor below is the belt to this braces.
      fileSystems."/host-nix/nix/store".neededForBoot = true;
      fileSystems."/host-nix/nix/var/nix/db".neededForBoot = true;

      systemd.services.nix-daemon.unitConfig.RequiresMountsFor = [
        "/host-nix/nix/store"
        "/host-nix/nix/var/nix/db"
      ];

      fileSystems."/nix/store" = lib.mkForce {
        overlay = {
          lowerdir = [ "/host-nix/nix/store" ];
          upperdir = "/nix/.rw-store/store";
          workdir = "/nix/.rw-store/work";
        };
        neededForBoot = true;
      };
    })
  ];
}
