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

  options.vzBuilder.debugAccess = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Authorise the keypair nixpkgs ships for its own builder VM, so the guest
      can be logged into for profiling:

        ssh -i "$(nix eval --raw -f . inputs.nixpkgs)/nixos/modules/profiles/keys/ssh_host_ed25519_key" \
            builder@vzbuilder.local systemd-analyze blame

      Both halves of that key are world-readable in the store, so this
      authorises an already-public key: anyone who can reach this VM on the
      NAT can then log in as a trusted user. Off by default. Turn it on for a
      session and turn it back off, rather than leaving it.
    '';
  };

  options.vzBuilder.hostStore = lib.mkOption {
    type = lib.types.enum [
      "off"
      "substituter"
      "overlay"
    ];
    default = "overlay";
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

      # Stage 1 is where the remaining boot time is, and at its default level
      # it says nothing about why it waits. `rd.systemd.log_level=debug` on the
      # kernel command line does not reach it -- this does.
      boot.initrd.systemd.settings.Manager.LogLevel = lib.mkIf cfg.debugAccess "debug";

      # Shutting the VM down between measurements beats waiting out the idle
      # timer:
      #
      #   ssh -p 31122 root@127.0.0.1 systemctl poweroff
      #
      # As `builder` that is refused -- "Call to PowerOff failed: Access
      # denied" -- because the session is neither local nor root. Authorising
      # root is lighter than the alternative: polkit is not enabled in this
      # guest at all, so a polkit rule is inert, and pulling polkit in costs a
      # service on every boot for a debugging convenience.
      users.users.root.openssh.authorizedKeys.keyFiles =
        lib.optional cfg.debugAccess "${modulesPath}/profiles/keys/ssh_host_ed25519_key.pub";

      # This VM has four device classes and no disk: virtio-net, virtiofs (the
      # key share, the host store, the host database and Rosetta), virtio-rng
      # and virtio-serial. NixOS's default initrd module set is sized for real
      # hardware -- SATA, NVMe, USB, SD, the lot -- and every one of those is a
      # module to load and a bus for udev to walk before the mounts can
      # proceed. Two waits of ~0.8s each sat in front of Mounting /sysroot and
      # Mounting /sysroot/nix/store because of it.
      #
      # If the guest ever stops booting after a device change, this list is the
      # first place to look, and `includeDefaultModules = true` is the way to
      # rule it out.
      boot.initrd.includeDefaultModules = false;
      boot.initrd.availableKernelModules = [
        "virtio_pci" # how every device below is discovered
        "virtio_net"
        "virtio_console" # hvc0, which the console= parameter names
        "virtio_rng"
        "fuse" # virtiofs is built on it
        "virtiofs"
        "overlay"
      ];
      boot.kernelModules = [
        "virtiofs"
        "overlay"
      ];

      # Nothing here has, or emulates, a TPM.
      boot.initrd.systemd.tpm2.enable = false;

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
        authorizedKeysFiles = lib.mkForce (
          [ "/var/keys/builder_ed25519.pub" ] ++ lib.optional cfg.debugAccess "/etc/ssh/authorized_keys.d/%u"
        );
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
        openssh.authorizedKeys.keyFiles = lib.optional cfg.debugAccess "${modulesPath}/profiles/keys/ssh_host_ed25519_key.pub";
        # Reading the *system* journal is the point of logging in: the console
        # is at log_level=warning, so it says nothing about the initrd.
        extraGroups = lib.optional cfg.debugAccess "systemd-journal";
      };
      users.groups.builder = { };

      # How the host finds this machine. macOS bootpd records the DHCP hostname
      # in /var/db/dhcpd_leases but serves no DNS, so DHCP alone resolves
      # nothing. mDNS does: mDNSResponder answers <hostName>.local natively,
      # with nothing configured on the host side.
      networking.hostName = "vzbuilder";

      # systemd-networkd rather than dhcpcd. dhcpcd spent 4.587s on the
      # critical chain to multi-user.target -- more than half of userspace --
      # because it probes and waits before declaring the lease usable.
      # networkd's client does not.
      networking.useNetworkd = true;

      # networkd needs the interface configured explicitly, and this is the
      # whole of it. `networking.useDHCP` is the legacy global switch: under
      # networkd it generates no .network unit, so networkd starts, matches
      # nothing, and the guest comes up with no address at all -- no lease, no
      # ARP entry, no mDNS name. Nothing logs an error; the host simply cannot
      # resolve vzbuilder.local, and a build sits on an open socket waiting for
      # a builder that will never answer.
      networking.useDHCP = false;
      systemd.network.networks."10-uplink" = {
        matchConfig.Name = "en*";
        networkConfig.DHCP = "ipv4";
        # Nothing waits on network-online.target here: the builder is reached
        # by name over mDNS, and sshd is socket-activated.
        linkConfig.RequiredForOnline = "no";
      };

      # No firewall on a builder that exists for a minute, on a host-only NAT,
      # reachable from one Mac. It cost 596ms of the boot it is not protecting.
      networking.firewall.enable = false;
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
      # One share for the whole of /nix, not one for the store and one for the
      # database. Both are needed and both live under it, so this is simply
      # less to configure.
      #
      # It was tried as a boot-time optimisation and is not one. systemd
      # rate-limits its mount monitor at five events per second and then backs
      # off for about a second; stage 1 trips that twice, which is ~1.6s of
      # this boot and the largest remaining cost. Dropping one mount did not
      # get under the threshold and changed nothing measurable. It is a known
      # systemd problem, systemd/systemd#28264, semi-fixed in later versions --
      # so it is worth re-measuring after a systemd bump, and not worth
      # attacking from here.
      fileSystems."/host-nix/nix" = {
        device = "hostnix";
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
      # The overlay store is named in exactly one place: the daemon's command
      # line. Every client, including the unprivileged `nix-daemon --stdio`
      # that ssh-ng runs as the `builder` user, reads `store = daemon` from
      # nix.conf and proxies here instead of trying to open the overlay store
      # itself -- which it cannot do, having no write access to the upper
      # layer. The command line beats nix.conf, so the daemon does not follow
      # `store = daemon` back into itself.
      nix.settings.store = "daemon";

      # `%` doubled because this lands in a systemd unit, where a single `%`
      # starts a specifier. An un-doubled `%3F` makes systemd fail to parse the
      # unit, so the daemon never starts and every client reports "cannot
      # connect to socket at /nix/var/nix/daemon-socket/socket" -- which looks
      # nothing like an escaping bug.
      systemd.services.nix-daemon.serviceConfig.ExecStart = [
        "" # clear the inherited definition rather than add a second one
        "@${config.nix.package}/bin/nix-daemon nix-daemon --daemon --store ${
          lib.replaceStrings [ "%" ] [ "%%" ] overlayStoreUri
        }"
      ];

      # The initrd carries a squashfs of the whole system closure -- 451 MiB
      # of it -- and in this mode nothing reads it: the system comes from the
      # host store through the overlay instead. Emptying it drops a second copy
      # of the closure from the image and the cost of decompressing it on every
      # boot, which is most of the cold-start time.
      #
      # Only safe here. With hostStore "substituter" or "off" the squashfs *is*
      # where the guest's system lives.
      netboot.storeContents = lib.mkForce [ ];

      # ...and drop the mount for it altogether. netboot marks /nix/.ro-store
      # neededForBoot, so stage 1 attaches a loop device to the squashfs and
      # waits for it -- for an image that is now empty and that nothing in this
      # mode reads, since /nix/store overlays the host store instead.
      #
      # The whole entry has to be replaced, not just `neededForBoot`. netboot
      # defines it with mkImageMediaOverride, and against that a mkForce on a
      # single attribute silently loses -- `neededForBoot` stayed true through
      # a rebuild and a boot. Forcing the entry itself wins, and `enable =
      # false` means no mount unit is generated at all.
      fileSystems."/nix/.ro-store" = lib.mkForce {
        enable = false;
        device = "none";
        fsType = "tmpfs";
      };

      # netboot registers the squashfs contents into the Nix database at boot.
      # The squashfs is empty here, so the service only fails -- the paths come
      # from the lower store's database instead.
      systemd.services.register-nix-paths.enable = lib.mkForce false;

      # A host key is installed from nixpkgs' fixed pair, so there is nothing
      # to generate at boot.
      services.openssh.hostKeys = lib.mkForce [ ];

      # A builder that lives for a minute has no use for a clock discipline
      # daemon, and it holds up the network target while it starts.
      services.timesyncd.enable = false;

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
      fileSystems."/host-nix/nix".neededForBoot = true;

      systemd.services.nix-daemon.unitConfig.RequiresMountsFor = [ "/host-nix/nix" ];

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
