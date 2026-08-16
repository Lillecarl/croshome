{
  inputs,
  pkgs,
  homeArgs,
  ...
}:
{
  imports = [
    inputs.home-manager.darwinModules.home-manager
    ./cocoa-way.nix
    ./aerospace.nix
    ./borders.nix
    ./ready.nix
    ./fuse.nix
    ./eurkey.nix
  ];

  system.stateVersion = 7;
  system.primaryUser = "lillecarl";

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

    # extra-* rather than plain substituters/trusted-public-keys, which are
    # lists that replace rather than append -- assigning them here would drop
    # cache.nixos.org, which is the whole default.
    extra-substituters = [ "https://lillecarl.cachix.org" ];
    extra-trusted-public-keys = [
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
