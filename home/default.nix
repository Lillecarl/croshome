{
  lib,
  inputs,
  platform,
  ...
}:
{
  # Everything below this line is shared by all three machines. What only one
  # kind of machine can do lives in ./darwin or ./linux, and what only one
  # machine does lives in ../hosts/<host>/home.nix.
  #
  # The two platform directories are chosen from `platform`, a specialArg that
  # the repo root derives from the system string with `lib.systems.elaborate`.
  # It has to come from outside: `imports` is resolved before `config` exists,
  # so reading `pkgs.stdenv.hostPlatform` here would ask the module system to
  # decide which modules define `pkgs` by first reading `pkgs`.
  imports = [
    inputs.catppuccin.homeModules.catppuccin
    ./agents.nix
    ./fish.nix
    ./fonts.nix
    ./github.nix
    ./helix.nix
    ./k9s.nix
    ./packages.nix
    ./tmux.nix
    ./vcs.nix
    ./yazi.nix
  ]
  ++ lib.optional platform.isDarwin ./darwin
  ++ lib.optional platform.isLinux ./linux;

  # `enable` is about to stop meaning "theme every port that is enabled" and
  # become a global on/off, with `autoEnable` carrying the old sense. Stating
  # both keeps today's behaviour through that change instead of inheriting
  # whichever default lands.
  catppuccin.enable = true;
  catppuccin.autoEnable = true;

  programs.home-manager.enable = true;

  # Exports XDG_{CONFIG,CACHE,DATA,STATE}_HOME as session variables. macOS has
  # no XDG layout of its own, and this config expects one on every machine.
  xdg.enable = true;

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  # The module rather than the bare package: it is what catppuccin themes, and
  # `bat` with the default theme is unreadable on this background.
  programs.bat.enable = true;
  programs.fd.enable = true;
  programs.htop.enable = true;
  programs.jq.enable = true;
  programs.lsd = {
    enable = true;
    enableFishIntegration = true;
  };
  programs.ripgrep.enable = true;

  programs.k9s.enable = true;
  programs.kubecolor.enable = true;
  programs.kubeswitch = {
    enable = true;
    enableFishIntegration = true;
  };

  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    # An attribute name that is not already a `Host`/`Match` line becomes
    # `Host <name>`, and the block takes OpenSSH directive names directly.
    settings."*" = {
      WarnWeakCrypto = "no";
      ServerAliveInterval = 15;
    };
  };
}
