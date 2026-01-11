{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:
{
  imports = [
    inputs.catppuccin.homeModules.catppuccin
    ../home/foot.nix
    ../home/fonts.nix
  ];
  config = {
    programs.kubecolor.enable = true;
    programs.k9s.enable = true;
    catppuccin.enable = true;
    programs.jq.enable = true;
    programs.ripgrep.enable = true;
    programs.fd.enable = true;
    programs.lsd = {
      enable = true;
      enableFishIntegration = true;
    };
    programs.home-manager.enable = true;
    programs.htop.enable = true;
    programs.tmux = {
      enable = true;
      shell = lib.getExe config.programs.fish.package;
      aggressiveResize = true;
      escapeTime = 0;
      sensibleOnTop = true;
      baseIndex = 1;
      keyMode = "vi";
      clock24 = true;
      extraConfig = # tmux
        ''
          bind -n M-h select-pane -L
          bind -n M-j select-pane -D
          bind -n M-k select-pane -U
          bind -n M-l select-pane -R
          # Use the modern terminfo for tmux
          set -g default-terminal "tmux-256color"

          # Tell tmux that 'foot' supports RGB (True Color), the leading comma is important
          set-option -sa terminal-features ',foot:RGB'
        '';
    };
    programs.fish = {
      enable = true;
      shellAbbrs = {
        kc = "kubectl";
        sc = "sudo systemctl";
        scu = "systemctl --user";
        jc = "journalctl --unit";
        jcu = "journalctl --user --unit";
        kns = "kubens";
      };
    };
    programs.jujutsu = {
      enable = true;
      settings = {
        user.name = "lillecarl";
        user.email = "git@lillecarl.com";
      };
    };
    programs.git = {
      enable = true;
      settings = {
        user.name = "lillecarl";
        user.email = "git@lillecarl.com";
      };
    };
    programs.jjui = {
      enable = true;
      settings = { };
    };
    programs.helix.enable = true;
    programs.direnv = {
      enable = true;
      nix-direnv.enable = true;
    };
    # Latest Lix is the coolest Nix currently
    nix = {
      settings.trusted-users = [ "lillecarl" ];
      settings.experimental-features = [
        "nix-command"
        "flakes"
        "read-only-local-store"
      ];
      package = pkgs.lixPackageSets.latest.lix;
      nixPath = [
        "nixpkgs=${inputs.nixpkgs.outPath}"
      ];
      registry = {
        nixpkgs.flake = inputs.nixpkgs;
        n.flake = inputs.nixpkgs;
      };
    };
    home = {
      username = "lillecarl";
      homeDirectory = "/home/lillecarl";
      shell.enableFishIntegration = true;
      stateVersion = "25.11";
      packages = with pkgs; [
        mosh
        gitui
        lazygit
        claude-code
        fish-lsp
        kubectl
        kubectx
        nerd-fonts.hack
        nixd
        nixfmt
        rclone
        stern
        viddy
        waypipe
        wl-clipboard
        sshuttle
      ];
      sessionVariables = {
        EDITOR = lib.getExe config.programs.helix.package;
      };
    };
    targets.genericLinux.enable = true;
  };
}
