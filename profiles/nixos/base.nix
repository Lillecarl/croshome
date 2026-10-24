# What every NixOS host here shares: the lillecarl account, the home-manager
# wiring, the Nix setup and the base services. A host imports this and adds
# its hardware, networking and anything it alone runs.
#
# Substituters and their keys stay in each host: NixOS adds cache.nixos.org
# at a priority this file cannot sit beside without reordering nix.conf.
#
# List-valued settings a host also extends are `lib.mkBefore`. Definitions
# concatenate in module order, and this file's land after the importing
# host's own, so without it a host's extra entries would come first.
{
  config,
  pkgs,
  lib,
  inputs,
  homeArgs,
  ...
}:
let
  ccacheDir = "/var/cache/ccache/cache";
in
{
  imports = [
    inputs.disko.nixosModules.disko
    inputs.home-manager.nixosModules.home-manager
    ../../modules/nixos
    ../../secrets
    ./podman.nix
    ./ollama.nix
    ./ttyd.nix
    ./terminfo.nix
  ];

  programs.fish.enable = true;
  users.users.lillecarl = {
    hashedPassword = "$y$j9T$U4zBBS9RMV9YMttHauO8k0$V.KT/P/AdBTXXT8f6p9EIlCsZV5UnaPDgEVtUvUJU3C";
    isNormalUser = true;
    openssh.authorizedKeys.keyFiles = [ ../../lillecarl.pub ];
    shell = pkgs.fish;
  };
  home-manager = {
    useGlobalPkgs = true;
    extraSpecialArgs = homeArgs;
    # Move aside any unmanaged file home-manager is about to replace,
    # instead of failing activation on it. The collision this covers:
    # anything that writes ~/.config/user-dirs.dirs before home-manager
    # links its own managed copy on the same switch.
    backupFileExtension = "hm-backup";
  };

  boot.kernelPackages = pkgs.linuxPackages_latest;
  # Support building crossPlatform with QEMU
  boot.binfmt.emulatedSystems = [
    {
      "x86_64-linux" = "aarch64-linux";
      "aarch64-linux" = "x86_64-linux";
    }
    .${pkgs.stdenv.hostPlatform.system}
  ];
  time.timeZone = "Europe/Stockholm";
  # Terminfo packages for terminals we're using
  environment.systemPackages = with pkgs.pkgsBuildBuild; [
    foot.terminfo
  ];
  # reference catppuccin whiskers so it doesn't get garbage collected every time you collect garbage.
  environment.etc.catppucin-whiskers.source =
    inputs.catppuccin.packages.${pkgs.stdenv.hostPlatform.system}.whiskers;
  environment.etc.nixpkgs.source = inputs.nixpkgs.outPath;
  programs.bash.shellInit = lib.mkBefore ''
    if [ -n "$CLAUDECODE" ]; then
      eval "$(DIRENV_LOG_FORMAT= ${lib.getExe pkgs.direnv} hook bash)"
      unset HTTPS_PROXY
    fi
  '';
  nix = {
    settings = {
      trusted-users = [ "lillecarl" ];
      experimental-features = lib.mkBefore [
        "nix-command"
        "flakes"
        "read-only-local-store"
        "ca-derivations"
        "dynamic-derivations"
        "recursive-nix"
        "configurable-impure-env"
      ];
      sandbox = "relaxed";
      # Without the mount a build using `ccacheStdenv` finds no directory
      # and fails.
      extra-sandbox-paths = [ ccacheDir ];
    };
    nixPath = lib.mkBefore [
      "nixpkgs=/etc/nixpkgs"
    ];
    registry = {
      nixpkgs.flake = inputs.nixpkgs;
      n.flake = inputs.nixpkgs;
    };
  };

  # Shared by every package that builds with `ccacheStdenv`, or sets
  # CCACHE_DIR to it. Not `programs.ccache`: with no `packageNames` it only
  # adds this directory and a setgid `nix-ccache` stats helper, and that
  # helper is a Perl script, which nixpkgs' wrapper integrity check refuses
  # (2026-10-24). `ccache -s` as root shows the same statistics.
  #
  # The cache is 0777: under `auto-allocate-uids` each build's group is its
  # own allocated id, with no supplementary groups, in a range no group or
  # ACL can name. The 0700 parent keeps local users out: Nix opens the mount
  # source as root and makes its own parents inside the sandbox, so builds
  # reach the cache through a parent they cannot enter on the host.
  systemd.tmpfiles.rules = lib.mkAfter [
    "d /var/cache/ccache 0700 root root -"
    "d ${ccacheDir} 0777 root root -"
  ];

  services.btrfs.autoScrub = {
    enable = true;
    interval = "monthly";
  };
  # Weekly discard: btrfs mounts without discard=async, so nothing trims
  # until this runs.
  services.fstrim.enable = true;

  programs.mosh = {
    enable = true;
    openFirewall = true;
  };
  # Ban hammer with a light touch: ten failures in ten minutes earns ten
  # minutes offline. A typo costs a coffee break, not an afternoon, and
  # localhost never counts. The default sshd jail applies; the module
  # raises sshd LogLevel to VERBOSE itself so failures are observable.
  services.fail2ban = {
    enable = true;
    maxretry = 10;
    bantime = "10m";
    ignoreIP = [ "127.0.0.1/8" ];
  };
  services.openssh = {
    enable = true;
    openFirewall = true;
  };
}
