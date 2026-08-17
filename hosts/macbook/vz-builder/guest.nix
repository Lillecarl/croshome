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
  pkgs,
  ...
}:
let
  cfg = config.virtualisation.linux-vz-builder;
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

  options.virtualisation.linux-vz-builder.debugAccess = lib.mkOption {
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

  options.virtualisation.linux-vz-builder.swap = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Format /dev/vdb as swap and enable it at boot. The host attaches that
      disk when `swapSize` is non-zero; see ./default.nix.
    '';
  };

  options.virtualisation.linux-vz-builder.hostStore = lib.mkOption {
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
        "virtio_blk" # the store disk, and the swap disk beside it
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

      # Build outputs, on a real disk instead of RAM.
      #
      # netboot puts the overlay's upper layer on a tmpfs, so every output a
      # build produced was charged to guest memory and capped at half of it --
      # 3.9 GiB of 8. A build bigger than that died, and the failure looked
      # like an ordinary out-of-space rather than a design limit.
      #
      # autoFormat becomes `x-systemd.makefs`, which systemd stage 1 handles;
      # the host hands over a freshly truncated image on every start, so blkid
      # finds no signature and it is formatted each boot. `formatOptions` no
      # longer exists in NixOS -- systemd-makefs takes none -- so the mkfs
      # defaults have to be acceptable as they are. They are: measured at
      # ~95ms, leaving the image sparse, because ext4 initialises its inode
      # tables lazily.
      #
      # supportedFilesystems is what puts mkfs.ext4 in the initrd at all. See
      # nixos/modules/tasks/filesystems/ext.nix -- it keys off this option and
      # not off the fileSystems entry below, so leaving it out gives a guest
      # that boots to a stage-1 failure.
      boot.initrd.supportedFilesystems = [ "ext4" ];
      fileSystems."/nix/.rw-store" = lib.mkForce {
        device = "/dev/vda";
        fsType = "ext4";
        autoFormat = true;
        neededForBoot = true;
        options = [ "noatime" ];
      };

      # Swap, on its own ephemeral disk. Nothing returns memory to the host
      # short of the VM exiting, so this is not about the host: it turns a
      # build that spikes past `memory` from an OOM kill into a slow build,
      # and it makes the root tmpfs evictable, tmpfs pages being swap-backed.
      #
      # Not `swapDevices`: NixOS only runs mkswap for that when a `size` is
      # set, which is the swapfile path and writes the whole file with dd on
      # every boot. On a raw device mkswap writes a header and returns.
      systemd.services.vz-builder-swap = lib.mkIf cfg.swap {
        description = "Format and enable the ephemeral swap disk";
        wantedBy = [ "multi-user.target" ];
        before = [ "nix-daemon.service" ];
        after = [ "systemd-modules-load.service" ];
        path = [ pkgs.util-linux ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          mkswap -L vzswap /dev/vdb
          swapon /dev/vdb
        '';
      };

      # Build scratch, on the guest's own disk beside the store layer.
      #
      # It used to be a virtiofs share of a host directory, which put it on the
      # SSD but gave it the *host's* clock. The guest runs about 70ms behind
      # macOS -- measured, repeatably -- so a file written through virtiofs came
      # back with an mtime slightly in the guest's future, and build systems
      # that compare mtimes to now say so. Meson and make call it clock skew,
      # and they are right.
      #
      # On ext4 the timestamps come from the same clock that reads them, so the
      # comparison is consistent no matter what the host thinks the time is.
      # The read-only store share is left as the only virtiofs in a build's
      # path, and it cannot skew anything: Nix normalises store timestamps to
      # the epoch, so nothing there is ever in the future.
      systemd.tmpfiles.rules = [
        # Nix's build directory. Root-owned: the daemon builds here, not users.
        "d /nix/.rw-store/build 0755 root root -"

        # Writable space for people, not just for the daemon. Without this the
        # disk is root-owned throughout, so an unprivileged session has nothing
        # but the tmpfs root -- /tmp, /var/tmp and $HOME all being 3.9 GiB of
        # RAM. That is the very limit this disk exists to remove, and it is
        # easy to miss, because builds work fine while interactive work does
        # not.
        #
        # A symlink rather than a bind mount, deliberately. /scratch has to be
        # short to be worth typing, and the root filesystem is a tmpfs, so a
        # symlink there is free and has no mount ordering to get wrong.
        #
        # 1777 matters as much as the path: this is where sandboxed builds
        # need to reach, and they run as nixbld1..N (uid 30001+, group
        # nixbld), not as builder. builder's own $HOME on the disk beside
        # this (below) is 0700 -- correct for a home directory, and exactly
        # wrong for anything a build has to traverse into, since a build
        # user is "other" there and 0700 gives other no execute bit at all.
        #
        # Confirmed the hard way: a session putting its work directory under
        # $HOME got seven silent build-shaped test failures -- not "denied",
        # just builds that never happened -- and two of them were in the
        # *control* run, which is the one report that is supposed to prove a
        # regression isn't there. Put working directories under /scratch, or
        # anywhere else world-traversable on this disk; never under $HOME.
        "d /nix/.rw-store/scratch 1777 root root -"
        "L /scratch - - - - /nix/.rw-store/scratch"
      ];

      # Socket activation, on TCP. systemd accepts any SOCK_STREAM so vsock
      # would work identically, but vsock needs a ProxyCommand in root's ssh
      # config and the nix-daemon is what dials out. Over the NAT interface no
      # privileged host configuration is required at all.
      services.openssh = {
        enable = true;
        startWhenNeeded = true;
        settings.PasswordAuthentication = false;

        # sshd allows 10 channels on one connection by default, and that is
        # too few for a client that opens many at once over a single link.
        # pynixd probes this guest by asking it about one system feature per
        # channel, all started together (`_probe_features` in
        # pynixd/store/daemon.py), so two systems and nine candidate features
        # is 18 channels at the same instant. sshd refused the last eight with
        # "Session request failed", and pynixd read that as a store that
        # failed to start: 18 consecutive failures and a 300s cooldown.
        # Reported as Lillecarl/nanopynix#167.
        #
        # 128 rather than 20, because the same limit applies to a build. This
        # is a single-tenant machine that exists only while a build runs, so
        # there is nothing here for the default to protect.
        settings.MaxSessions = 128;

        # Off because the key files arrive over virtiofs, and Virtualization.
        # framework does not pass ownership through: /var/lib/vz-builder/keys
        # is 0:0 on the Mac and shows up as 1000:1000 -- `builder` -- in here.
        # StrictModes requires an authorized_keys file to be owned by root or
        # by the user logging in, so that mapping quietly authorises `builder`
        # and refuses every other account. `vzrun --root` failed on exactly
        # this, with "Permission denied (publickey)" and no hint as to why.
        #
        # The check exists to stop one guest user from planting keys for
        # another. It cannot do that here: the share is read-only and its
        # contents come from the host, so no process in this VM can write it.
        settings.StrictModes = false;
        # These paths carry no %u, so they are consulted for every user rather
        # than per account: the builder key and anything in `authorizedKeys`
        # log in as `root` as well as `builder`. That is what `vzrun --root`
        # uses. It is a disposable VM on a host-only NAT, and `builder` is a
        # trusted Nix user that can already run anything here by submitting a
        # derivation, so root adds no reachable privilege.
        #
        # authorized_keys is the interactive half and arrives on the same share
        # as the builder key; ./default.nix writes it at VM start, so it is
        # empty rather than missing when nobody is authorised.
        authorizedKeysFiles = lib.mkForce (
          [
            "/var/keys/builder_ed25519.pub"
            "/var/keys/authorized_keys"
          ]
          ++ lib.optional cfg.debugAccess "/etc/ssh/authorized_keys.d/%u"
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
        # Home on the disk, not on the root tmpfs. Anything an interactive
        # session leaves in $HOME would otherwise be charged to RAM and capped
        # at half of it. The mount is neededForBoot, so it is present well
        # before user activation creates this.
        home = "/nix/.rw-store/home";
        createHome = true;
        openssh.authorizedKeys.keyFiles = lib.optional cfg.debugAccess "${modulesPath}/profiles/keys/ssh_host_ed25519_key.pub";
        # Reading the *system* journal is the point of logging in: the console
        # is at log_level=warning, so it says nothing about the initrd.
        extraGroups = [ "wheel" ] ++ lib.optional cfg.debugAccess "systemd-journal";
      };
      users.groups.builder = { };

      # `builder` is pseudo-root: wheel, and wheel needs no password. It has no
      # password to give -- it authenticates by key -- so without this sudo is
      # not merely inconvenient, it is unusable.
      #
      # This grants nothing that was not already reachable. `builder` is a
      # trusted Nix user, so it can run arbitrary code as root in this VM by
      # submitting a derivation, and the same keys log in as root directly.
      # What it buys is that `vzrun sudo ...` works in the middle of a session
      # rather than needing a second connection as another user.
      security.sudo.wheelNeedsPassword = false;

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
        # No experimental-features here. ../default.nix hands the host's list
        # over, and that list is the authority for both machines. This block
        # used to name `nix-command` and `flakes`, which made the guest quietly
        # disagree with the host about anything else -- `dynamic-derivations`,
        # for one. The `mkIf` branch further down still names two, because
        # those describe this guest's own store topology and mean nothing on
        # the host.
        # Two different knobs, both set to "use everything", because this VM
        # exists only while a build runs and has nothing to hold capacity back
        # for.
        #
        # max-jobs is how many jobs this machine builds in parallel, and it
        # takes `auto` -- the number of CPUs. (The maxJobs column in the host's
        # /etc/nix/machines is a different field, dispatch rather than
        # scheduling, and takes an integer only.)
        max-jobs = "auto";
        # Scratch on the guest's own disk, beside the store's write layer and
        # on the same filesystem as it. Not the root tmpfs, which would charge
        # every build's temporary files to RAM, and no longer a virtiofs share,
        # which gave them host timestamps. See the tmpfiles rule above.
        build-dir = "/nix/.rw-store/build";

        # cores is how many CPUs each individual job gets. 0 is its sentinel
        # for "all of them": the builder passes NIX_BUILD_CORES = buildCores,
        # falling back to getDefaultCores() when that is 0.
        cores = 0;
      };

      # The same nixpkgs the Mac resolves, so `<nixpkgs>` and `nixpkgs#foo`
      # mean in here what they mean out there.
      #
      # Without this the guest keeps the NixOS defaults, which point at root's
      # channel profile -- a path that does not exist in this VM -- and carries
      # no `nixpkgs` registry entry at all. So `nix run nixpkgs#jq` in the
      # guest would go to GitHub for a nixpkgs the host already has on disk.
      #
      # Inherited from the host rather than resolved again here. ./default.nix
      # reads it out of the host's own registry, so the two cannot drift, and
      # so the guest names the *same store path* -- evaluating identical
      # content at a different path would hash every derivation differently
      # and miss the cache. `pkgs.path` did exactly that.

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
        # `immutable` promises SQLite the file will not change, while the
        # host's daemon writes to it whenever anything builds on the Mac, which
        # looks alarming until you notice the layer below makes the same
        # promise. overlayfs already requires that a lowerdir not be modified
        # while mounted -- do it anyway and the behaviour is undefined -- so
        # the guest's view of the store files is frozen at mount time too. The
        # database view and the file view are frozen together and therefore
        # agree: neither sees paths the host adds afterwards. It is also why
        # nothing here contends on the host's derivation locks; the guest locks
        # in its own writable layer.
        #
        # What is left is the narrower case of the host checkpointing its WAL
        # into the main database file mid-read, or collecting garbage out from
        # under a mounted lower layer. Both are the same "lowerdir changed"
        # hazard overlayfs already names. Switch hostStore to "substituter" if
        # it ever misbehaves.
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

      systemd.services.nix-daemon.unitConfig.RequiresMountsFor = [
        "/host-nix/nix"
        "/nix/.rw-store" # build-dir lives here, as does the store write layer
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
