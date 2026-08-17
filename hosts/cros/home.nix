{ inputs, pkgs, ... }:
{
  # This host does NOT import ../../home. The ChromeOS machine is slow enough
  # that every package it does not need is a cost, and its whole job is to run
  # a terminal and reach the other two machines. So it names the few modules it
  # wants instead of taking the shared set and subtracting from it.
  #
  # ../../home/linux/foot.nix is imported directly rather than through
  # ../../home/linux, which also carries Emacs, waypipe and the agent tooling.
  imports = [
    inputs.catppuccin.homeModules.catppuccin
    ../../home/fonts.nix
    ../../home/linux/fonts.nix
    ../../home/linux/foot.nix
  ];

  home.username = "lillecarl";
  home.homeDirectory = "/home/lillecarl";
  home.stateVersion = "25.11";

  # Crostini is a Debian container, not NixOS, so home-manager has to set up
  # what a NixOS module would otherwise own: the session variables, the locale
  # archive and the desktop entries.
  targets.genericLinux.enable = true;
  home.shell.enableFishIntegration = true;

  # Exports XDG_{CONFIG,CACHE,DATA,STATE}_HOME as session variables, the same
  # as ../../home/default.nix does for the other two machines. This config
  # expects an XDG layout everywhere, and Crostini is the machine with nothing
  # underneath it to set one.
  xdg.enable = true;

  programs.home-manager.enable = true;
  programs.fish.enable = true;

  # Themes foot, which is the one thing on this machine with a colour scheme.
  catppuccin.enable = true;
  catppuccin.autoEnable = true;

  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    settings."*" = {
      WarnWeakCrypto = "no";
      # The link to these machines drops often enough that this matters more
      # here than anywhere else.
      ServerAliveInterval = 15;
    };
  };

  home.packages = with pkgs; [
    # Reconnects the ssh sessions this machine exists to hold open.
    autossh
    # Survives the roaming and the suspends that break a plain ssh session.
    mosh
  ];

  # The other two hosts get this from their system configuration. Here there is
  # no system configuration, so home-manager manages the Nix that ChromeOS runs.
  nix = {
    package = pkgs.nix;
    settings.trusted-users = [ "lillecarl" ];
    settings.experimental-features = [
      "nix-command"
      "flakes"
      "read-only-local-store"
      "ca-derivations"
      "dynamic-derivations"
      "recursive-nix"
    ];
    nixPath = [ "nixpkgs=${inputs.nixpkgs.outPath}" ];
    registry = {
      nixpkgs.flake = inputs.nixpkgs;
      n.flake = inputs.nixpkgs;
    };
  };
}
