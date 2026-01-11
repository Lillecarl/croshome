{
  selfStr,
  config,
  pkgs,
  lib,
  osConfig,
  inputs,
  ...
}:
{
  imports = [
    inputs.catppuccin.homeModules.catppuccin
    ./foot.nix
    ./fonts.nix
    ./vcs.nix
    ./modules/xonsh.nix
  ];
  config = {
    home.stateVersion = osConfig.system.stateVersion;
    home.packages = with pkgs; [
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
      # Python LSP and plugins
      python3Packages.python-lsp-server
      python3Packages.pylsp-mypy
      python3Packages.python-lsp-ruff
      python3Packages.pylsp-rope
    ];
    programs.kubeswitch = {
      enable = true;
      enableFishIntegration = true;
    };
    catppuccin.enable = true;
    programs.htop.enable = true;
    programs.kubecolor.enable = true;
    programs.k9s.enable = true;
    programs.xonsh = {
      enable = true;
      package = pkgs.xonsh.override {
        python3 = pkgs.python3.override {
          packageOverrides = self: pypkgs: {
            xonsh = pypkgs.xonsh.overrideAttrs {
              version = "0.22.0";
              doCheck = false;
              doInstallCheck = false;
              src = builtins.fetchTree {
                type = "github";
                owner = "xonsh";
                repo = "xonsh";
                ref = "0.22.0";
              };
            };
          };
        };
      };
      fishCompletion.enable = true;
      extraPackages =
        ps: with ps; [
          xonsh.xontribs.xontrib-abbrevs
          sh
        ];
    };
    programs.fish = {
      enable = true;
      shellInit = # fish
        ''
          set --global --export EDITOR hx
        '';
    };
    xdg.configFile."fish/functions".source =
      config.lib.file.mkOutOfStoreSymlink "${selfStr}/home/fish/functions";
    xdg.configFile."fish/conf.d".source =
      config.lib.file.mkOutOfStoreSymlink "${selfStr}/home/fish/conf.d";
    programs.lsd.enable = true;
    programs.ripgrep.enable = true;
    programs.fd.enable = true;
    programs.jq.enable = true;

    # emacs base configuration
    programs.emacs = {
      enable = true;
      package = pkgs.emacs-pgtk;
      extraPackages =
        ep: with ep; [
          which-key
          vterm
          meow
          consult
          vertico
          orderless
          nix-mode
          nix-ts-mode
          clipetty
          multiple-cursors
          catppuccin-theme
          corfu
          corfu-terminal
          cape
          treesit-grammars.with-all-grammars
        ];
    };
    # emacs symlinks
    home.file.".emacs.d/init.el".source =
      config.lib.file.mkOutOfStoreSymlink "${selfStr}/home/emacs/init.el";
    home.file.".emacs.d/early-init.el".source =
      config.lib.file.mkOutOfStoreSymlink "${selfStr}/home/emacs/early-init.el";
    home.file.".emacs.d/config".source =
      config.lib.file.mkOutOfStoreSymlink "${selfStr}/home/emacs/config";

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
          source-file ~/.config/tmux/linked.conf

          bind -n M-h select-pane -L
          bind -n M-j select-pane -D
          bind -n M-k select-pane -U
          bind -n M-l select-pane -R
          # Use the modern terminfo for tmux
          set -g default-terminal "tmux-256color"

          # Tell tmux that 'foot' supports RGB (True Color)
          # The leading comma is important
          set-option -sa terminal-features ',foot:RGB'
        '';
    };
    xdg.configFile."tmux/linked.conf".source =
      config.lib.file.mkOutOfStoreSymlink "${selfStr}/home/tmux-linked.conf";

    programs.helix = {
      enable = true;
      defaultEditor = true;
      extraPackages = [
        pkgs.bash-language-server
        pkgs.fish-lsp
        pkgs.tombi
        pkgs.vscode-json-languageserver
        pkgs.yaml-language-server
        # pkgs.pyright
        pkgs.ty
        pkgs.ruff
      ];
    };
    programs.direnv.enable = true;
  };
}
