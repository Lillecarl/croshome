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
    ./fish.nix
    ./fonts.nix
    ./foot.nix
    ./github.nix
    ./vcs.nix
    ./k9s.nix
    ./yazi.nix

    ./modules/xonsh.nix
  ];
  config = {
    home.stateVersion = osConfig.system.stateVersion;
    # ~/.local/bin
    home.file.".local/bin".source = config.lib.file.mkOutOfStoreSymlink "${selfStr}/home/localbin";
    home.sessionPath = [
      "${config.home.homeDirectory}/.local/bin"
    ];
    lib.packages.gemini-cli = (
      pkgs.gemini-cli.overrideAttrs (
        finalAttrs: previousAttrs: {
          version = "0.37.2";
          src = pkgs.fetchFromGitHub {
            owner = "google-gemini";
            repo = "gemini-cli";
            tag = "v${finalAttrs.version}";
            hash = "sha256-jmVYARto5NoqX1DbT+jYQOTzMkeSi0Z7A5oKDN5fCnY=";
          };
          npmDepsHash = "sha256-Hxxi2eKDLXucZLhUswcQ3kVEKoRNbs81m6IFr+CYxzs=";
          npmDeps = pkgs.fetchNpmDeps {
            inherit (finalAttrs) src;
            hash = finalAttrs.npmDepsHash;
          };
          patches = previousAttrs.patches or [ ] ++ [
            ../patches/gemini-keep-trying.patch
            ../patches/gemini-less-yolo.patch
          ];
        }
      )
    );
    home.packages = with pkgs; [
      config.lib.packages.gemini-cli
      atuin
      bat
      just
      jj-hunk
      claude-code
      fish-lsp
      fzf
      gitui
      kubectl
      kubectl-explore
      kubectx
      lazygit
      nerd-fonts.hack
      nixd
      nixfmt
      rclone
      sshuttle
      stern
      viddy
      waypipe
      wl-clipboard
      # # Python LSP and plugins
      # python3Packages.python-lsp-server
      # python3Packages.pylsp-mypy
      # python3Packages.python-lsp-ruff
      # python3Packages.pylsp-rope
    ];
    programs.kubeswitch = {
      enable = true;
      enableFishIntegration = true;
    };
    catppuccin.enable = true;
    programs.htop.enable = true;
    programs.kubecolor.enable = true;

    programs.xonsh = {
      enable = true;
      package = pkgs.xonsh.override {
        python3 = pkgs.python3.override {
          packageOverrides = self: pypkgs: {
            xonsh =
              let
                version = "0.22.8";
              in
              pypkgs.xonsh.overrideAttrs {
                inherit version;
                doCheck = false;
                doInstallCheck = false;
                src = builtins.fetchTree {
                  type = "github";
                  owner = "xonsh";
                  repo = "xonsh";
                  ref = version;
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
          (trivialBuild {
            pname = "meow-vterm";
            version = "0-unstable";
            src = pkgs.fetchFromGitHub {
              owner = "accelbread";
              repo = "meow-vterm";
              rev = "fc7e86a268b523ca12ff451e91aabe5485fbc975";
              hash = "sha256-oWWnyxTT/xdMq4CxLKb8BtjsPajg5sMctOq4dPHZzJk=";
            };
            packageRequires = [
              meow
              vterm
            ];
          })
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

          # Use the modern terminfo for tmux
          set -g default-terminal "tmux-256color"

          # Tell tmux that 'foot' supports RGB (True Color)
          # The leading comma is important
          set-option -sa terminal-features ',foot:RGB'
        '';
    };
    xdg.configFile."tmux/linked.conf".source =
      config.lib.file.mkOutOfStoreSymlink "${selfStr}/home/tmux-linked.conf";

    home.file.".claude/settings.json".source =
      config.lib.file.mkOutOfStoreSymlink "${selfStr}/home/claude/settings.json";
    home.file.".claude/skills".source =
      config.lib.file.mkOutOfStoreSymlink "${selfStr}/home/claude/skills";
    home.file.".gemini/skills".source =
      config.lib.file.mkOutOfStoreSymlink "${selfStr}/home/claude/skills";

    programs.helix = {
      enable = true;
      defaultEditor = true;
      extraPackages = [
        pkgs.bash-language-server
        pkgs.fish-lsp
        pkgs.marksman
        pkgs.ruff
        pkgs.tombi
        pkgs.ty
        pkgs.vscode-langservers-extracted
        pkgs.yaml-language-server
      ];
    };
    programs.direnv.enable = true;
  };
}
