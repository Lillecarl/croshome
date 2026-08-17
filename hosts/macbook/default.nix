{
  inputs,
  pkgs,
  homeArgs,
  ...
}:
{
  imports = [
    inputs.home-manager.darwinModules.home-manager
    ./ai-rebuild.nix
    ./linux-builder.nix
    ./vz-builder
    ./cocoa-way.nix
    ./aerospace.nix
    ./borders.nix
    ./ready.nix
    ./fuse.nix
    ./eurkey.nix
    # The darwin counterpart of the import in hosts/hetztop/default.nix. Same
    # input, same reason: nanopynix is `flake = false`, so this is the source
    # tree and no second flake is evaluated.
    "${inputs.nanopynix}/pynixd/nix/darwin"
    ./pynixd.nix
    ../../secrets
  ];

  system.stateVersion = 7;
  system.primaryUser = "lillecarl";

  # The `dc1` WireGuard key, carried off `nub` before that machine was
  # decommissioned. ../../secrets/secrets.nix says who may decrypt it and why
  # it was moved rather than reissued.
  #
  # Here and not in ../../secrets/default.nix, which is the file that documents
  # the shape of these entries. Both this host and hetztop import that file, so
  # an entry there is an entry on both, and hetztop has no use for this key --
  # it would decrypt it every activation and place it for nothing.
  #
  # No `path`, so it lands at /run/agenix/wg-dc1-key, and that is where it
  # should stay. There is no nix-darwin counterpart to `networking.wireguard`;
  # the darwin option is `networking.wg-quick.interfaces`, which never writes
  # the key into its world-readable /etc/wireguard/dc1.conf -- it applies
  # `privateKeyFile` at runtime through a generated PostUp calling `wg set`. So
  # pointing that at `config.age.secrets.wg-dc1-key.path` is enough and a
  # custom location buys nothing.
  #
  # Nothing brings the tunnel up yet. When something does, expect an ordering
  # hazard: wg-quick's launchd daemon and agenix's activate-agenix daemon are
  # both RunAtLoad with nothing sequencing them, so on a cold boot wg-quick can
  # start before the secret is on the ramdisk. Its KeepAlive should retry it
  # into success -- worth confirming with a real reboot rather than assuming.
  # Commented out until ../../secrets/wg-dc1.key.age exists. `file` is a path,
  # which Nix resolves at evaluation time, so naming a file that is not there
  # yet does not fail later at activation -- it stops this whole host from
  # evaluating, and `sudo ai-rebuild` fails on a font change with an error
  # about WireGuard.
  #
  # Uncomment in the same commit that adds the file. To create it, on nub while
  # that machine still boots:
  #
  #   sudo cat /etc/wireguard/dc1.key |
  #     nix run --file . pkgs.age -- \
  #       -r "age1gpep8sqp2ze8kyl82tlt2mkh58e0x933a650al2x9uavj8gnmpdq8zqdmz" \
  #       -r "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA3g8vwXRMHonL65HEEzxJM0B7LiUMSRyJwYdKNNn16L" \
  #       -a -o secrets/wg-dc1.key.age
  #
  # Then check it against the running tunnel before nub is wiped:
  #
  #   nix run --file . pkgs.agenix -- -d secrets/wg-dc1.key.age \
  #     -i secrets/identity.age | wg pubkey     # must equal
  #   sudo wg show dc1 public-key               # this
  #
  # age.secrets.wg-dc1-key.file = ../../secrets/wg-dc1.key.age;

  # The second builder, on Apple's hypervisor. It runs only while a build needs
  # it, so it sits alongside the always-on QEMU one rather than replacing it --
  # and the QEMU one is also what builds this one's guest image, which is why
  # removing it is a later step and not this one.
  nix.linux-vz-builder.enable = true;
  # `auto` is not available here: /etc/nix/machines parses this column with
  # string2Int<unsigned int> and throws on anything else, so it is a number or
  # nothing. This is that number for this Mac (`sysctl -n hw.ncpu`), and it
  # lives in the host file rather than the module because it is a fact about
  # the machine. The VM's own vCPU count needs no such treatment -- it reads
  # hw.ncpu itself at start-up.
  nix.linux-vz-builder.maxJobs = 15;
  # Half of this Mac's 24 GiB, up from the module's 8 GiB default. A fact about
  # the machine, so it sits here next to maxJobs rather than in the module.
  #
  # Read it as a ceiling the host never gets back below while the VM runs: the
  # framework backs guest RAM lazily, so an idle guest still costs little, but
  # a guest that has once touched 12 GiB keeps it until the VM exits. That is
  # what `idleTimeout` is for.
  nix.linux-vz-builder.memory = 12288;
  # What `vzrun` logs in with. This is the public half of ~/.ssh/id_ed25519,
  # so it is checked in on purpose -- the alternative is reading a path outside
  # the repo at evaluation time, which makes the build depend on this Mac.
  nix.linux-vz-builder.authorizedKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF4AwtWUz3usygb2J6owsUJs4X2yTchIGZyI+VDE76tF"
  ];
  # Taste, not a builder concern, so it goes here rather than into the module.
  #
  # A module argument and not a bare attribute set: `pkgs` inside a deferred
  # module is the *guest's* package set, aarch64-linux. Reading the `pkgs` of
  # this file would put a darwin build of terminfo into a NixOS system.
  nix.linux-vz-builder.extraModules = [
    (
      { pkgs, ... }:
      {
        # kitty sets TERM=xterm-kitty, which no other machine has heard of. An
        # interactive `vzrun` from a kitty window otherwise lands in a shell
        # where every curses program says "unknown terminal type" -- clear,
        # less and any TUI included. The terminfo entry alone, not kitty.
        environment.systemPackages = [ pkgs.kitty.terminfo ];
      }
    )
  ];

  # HostName is unset out of the box, which lets macOS derive `hostname`
  # dynamically -- currently to garbage bytes.
  networking.hostName = "macbook";
  networking.localHostName = "not-linux"; # Bonjour: not-linux.local
  networking.computerName = "not-linux"; # Finder / AirDrop / Sharing

  # nix-darwin only touches users listed in knownUsers; uid must match the
  # existing account or activation refuses to touch it.
  users.knownUsers = [ "lillecarl" ];
  users.users.lillecarl = {
    name = "lillecarl";
    uid = 501;
    gid = 20; # staff
    home = "/Users/lillecarl";
    shell = pkgs.fish;
  };

  # /etc/zshrc still needs managing: zsh remains root's and macOS' fallback shell.
  programs.zsh.enable = true;
  programs.fish.enable = true;
  environment.shells = [
    pkgs.fish
    pkgs.zsh
  ];

  security.pam.services.sudo_local.touchIdAuth = true;

  # Applied with `hidutil` on activation; the activate-system launchd daemon
  # reapplies it at boot, which is what makes it stick.
  # Both are in units of 15ms: 15 = 225ms before repeat starts, 2 = 30ms
  # between repeats. These are the fastest values the System Settings sliders
  # offer; 10 and 1 go beyond them.
  system.defaults.NSGlobalDomain.InitialKeyRepeat = 15;
  system.defaults.NSGlobalDomain.KeyRepeat = 2;
  # Otherwise holding a letter key opens the accent picker instead of repeating.
  system.defaults.NSGlobalDomain.ApplePressAndHoldEnabled = false;
  # ctrl+cmd drag moves a window from anywhere on it, not just the title bar.
  system.defaults.NSGlobalDomain.NSWindowShouldDragOnGesture = true;

  system.keyboard.enableKeyMapping = true;
  system.keyboard.swapLeftCtrlAndFn = true;
  # Apple ISO keyboards report the key left of 1 as Non-US \ (0x64), which
  # US-style layouts render as §/±; remap it to Grave/Tilde (0x35).
  system.keyboard.nonUS.remapTilde = true;

  # GUI apps go here: nix-darwin rsyncs their .app bundles into
  # /Applications/Nix Apps, which Spotlight and Launchpad index.
  # Their user-level config lives in ../../home.
  environment.systemPackages = [
    pkgs.kitty
    pkgs.firefox-bin # pkgs.firefox is a source build on darwin and is not cached
  ];

  # Symlinked into /Library/Fonts/Nix Fonts, so every user and every
  # application sees the font, and it is there before home-manager activates.
  # ../../home/fonts.nix holds the Linux half and installs nothing here, to
  # keep macOS from registering the same three families twice.
  fonts.packages = [ pkgs.nerd-fonts.hack ];

  # nixpkgs' default `nix` tracks the conservative release; take the newest one
  # nixpkgs ships instead.
  nix.package = pkgs.nixVersions.latest;

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
      "ca-derivations"
      "dynamic-derivations"
    ];
    trusted-users = [ "@admin" ];

    # NixOS marks its small generated files -- unit files, /etc fragments --
    # `allowSubstitutes = false`, because building them is cheaper than a round
    # trip. That reasoning holds only where they can be built. On a Mac they
    # are aarch64-linux and cannot be, so the flag turns a fetch into a hard
    # platform mismatch: it is what made the Linux builder need 215 local
    # builds instead of 21. Fetching them costs a couple of MiB.
    always-allow-substitutes = true;

    # The plain names, not extra-*. These options are lists, so the module
    # system merges the definitions: nixpkgs states cache.nixos.org and this
    # appends to it. It does not replace it.
    #
    # `extra-*` appends too, so the nix.conf was already correct. What it did
    # not do is reach `config.nix.settings.substituters`, which stayed at
    # cache.nixos.org alone. Anything that reads that option to pass the
    # setting on -- the way ./vz-builder/default.nix hands the guest this
    # host's experimental-features -- saw no cache at all. Matches hetztop.
    substituters = [ "https://lillecarl.cachix.org" ];
    trusted-public-keys = [
      "lillecarl.cachix.org-1:NN/LLMg7mbyvZCu32Qlo8LpSHqNw7Rr3VBCEYQvRpT0="
    ];

    # Defaults to true on darwin, where the store normally sits on a
    # case-insensitive volume: two paths in one NAR that differ only in case
    # cannot both exist, so Nix renames the later ones to `foo~nix~case~hack~1`
    # on unpack and undoes it when re-serialising. The store is on a
    # case-sensitive subvolume here, so the collision cannot happen and the
    # mangling is pure noise -- and anything reading the store directly (a
    # compiler looking for a header, a grep) sees the real names.
    #
    # Only affects unpacking from here on. Any path already on disk with a
    # hacked name keeps it and will re-serialise wrong, so a store that has
    # been through both settings is worth a `nix store verify` if something
    # looks off; a freshly reinstalled one has nothing to convert.
    use-case-hack = false;

    # Off by default on darwin; Nix drives Seatbelt (sandbox-exec) here rather
    # than namespaces. "relaxed" sandboxes everything but lets a derivation
    # marked __noChroot opt out.
    sandbox = "relaxed";
  };

  # Expose the locked nixpkgs at a stable path, and point both the channel-style
  # lookup and the flake registry at it.
  environment.etc.nixpkgs.source = inputs.nixpkgs.outPath;
  nix.nixPath = [ "nixpkgs=/etc/nixpkgs" ];
  # Not /etc/nixpkgs: a `path:` registry entry is copied into the store without
  # resolving symlinks, and /etc/nixpkgs is one, so flake lookups landed on a
  # symlink instead of a tree. `flake` pins the store path plus narHash/rev.
  nix.registry.nixpkgs.flake = inputs.nixpkgs;

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "hm-bak";
    extraSpecialArgs = homeArgs;
    users.lillecarl = import ./home.nix;
  };
}
