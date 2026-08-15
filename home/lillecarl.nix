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
    programs.ssh = {
      enable = true;
      enableDefaultConfig = false;
      matchBlocks."*" = {
        extraOptions.WarnWeakCrypto = "no";
      };
    };
    lib.packages = {
      opencode =
        let
          latestRelease = builtins.fromJSON (
            builtins.readFile (
              builtins.fetchurl {
                url = "https://api.github.com/repos/anomalyco/opencode/releases/latest";
                name = "opencode-latest-release.json";
              }
            )
          );
          tag = latestRelease.tag_name;
          version = lib.strings.removePrefix "v" tag;
          arch = if pkgs.stdenv.hostPlatform.isx86_64 then "x64" else "arm64";
        in
        inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.opencode.overrideAttrs (
          final: prev: {
            inherit version;
            src = builtins.fetchurl {
              url = "https://github.com/anomalyco/opencode/releases/download/${tag}/opencode-linux-${arch}.tar.gz";
              name = "opencode-${tag}.tar.gz";
            };
          }
        );
      pi =
        let
          latestRelease = lib.pipe { } [
            (
              x:
              builtins.fetchurl {
                url = "https://api.github.com/repos/earendil-works/pi/releases/latest";
                name = "pi-latest-release.json";
              }
            )
            builtins.readFile
            builtins.fromJSON
            (x: {
              tag = x.tag_name;
              version = lib.strings.removePrefix "v" x.tag_name;
              arch = if pkgs.stdenv.hostPlatform.isx86_64 then "x64" else "arm64";
              tarball = x.tarball_url;
            })
          ];
          package = (pkgs.callPackage ../../nix-pi/pi.nix { }).overrideAttrs (pa: {
            inherit (latestRelease) version;
            src = fetchTarball { url = latestRelease.tarball; };
          });
        in
        package.overrideAttrs (pa: {
          postFixup = ''
            wrapProgram $out/bin/pi --prefix PATH : ${lib.makeBinPath [
              pkgs.ripgrep
              pkgs.fd
              pkgs.nodejs
            ]}
          '';
        });
      omp =
        let
          craneLib = inputs.crane.mkLib pkgs;
          bun2nix = inputs.bun2nix.packages.${pkgs.stdenv.hostPlatform.system}.default;
          ompSrc = builtins.path {
            path = inputs.oh-my-pi.outPath;
            name = "omp-source";
          };
          natives = pkgs.callPackage (inputs.oh-my-pi + "/nix/omp/rust-natives.nix") {
            inherit craneLib;
            src = ompSrc;
          };
        in
        pkgs.callPackage (inputs.oh-my-pi + "/nix/omp/package.nix") {
          inherit bun2nix;
          src = ompSrc;
          inherit natives;
        };
    };

    home.packages = with pkgs; [
      # opencode
      # pi-coding-agent
      claude-code
      config.lib.packages.opencode
      config.lib.packages.pi
      inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.antigravity-cli
      inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.kilocode-cli
      inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.omp
      inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.reasonix
      codex # OpenAI
      # config.lib.packages.omp
      playwright-mcp
      mcp-nixos
      mcp-gateway
      context7-mcp
      # The rest
      binutils
      ncdu
      sd
      atuin
      bat
      just
      jj-hunk
      fish-lsp
      fzf
      gitui
      inotify-tools
      kubectl
      kubectl-explore
      kubectx
      lazygit
      nerd-fonts.hack
      nixd
      nixfmt
      sbomnix
      rclone
      sshuttle
      stern
      viddy
      waypipe
      wireguard-tools
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
      enable = false;
      package = pkgs.xonsh.override {
        python3 = pkgs.python3.override {
          packageOverrides = self: pypkgs: {
            xonsh =
              let
                version = "0.23.2";
              in
              pypkgs.xonsh.overrideAttrs {
                inherit version;
                doCheck = false;
                doInstallCheck = false;
                src = fetchTree {
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
      terminal = "tmux-256color";
      tmuxp.enable = true;
      extraConfig = # tmux
        ''
          source-file ~/.config/tmux/linked.conf
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
        pkgs.vscode-langservers-extracted
        pkgs.yaml-language-server
        pkgs.pyright
      ];
      languages = {
        language-server.pyright = {
          command = "${lib.getExe' pkgs.pyright "pyright-langserver"}";
          args = [ "--stdio" ];
          config.pyright = {
            typeCheckingMode = "strict";
            disableOrganizeImports = false;
          };
        };
        language-server.ruff = {
          command = "${lib.getExe pkgs.ruff}";
          args = [
            "server"
            "--preview"
          ];
        };
        language = [
          {
            name = "python";
            language-servers = [
              "pyright"
              "ruff"
            ];
            auto-format = true;
          }
        ];
      };
    };
    programs.direnv.enable = true;
  };
}
