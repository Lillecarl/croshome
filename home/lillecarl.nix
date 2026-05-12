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
      gemini-cli = (
        pkgs.gemini-cli.overrideAttrs (
          finalAttrs: previousAttrs: {
            version = "0.41.1";
            src = pkgs.fetchFromGitHub {
              owner = "google-gemini";
              repo = "gemini-cli";
              tag = "v${finalAttrs.version}";
              hash = "sha256-8T13ROsE6NVR120NbFThADjSYy1PApAXqdHzclSA2yc=";
            };
            npmDepsHash = "sha256-YHo3mAG9UlEg8J5SCzCu2YhKdlz7lFPon5SweKWQ8rk=";
            npmDeps = pkgs.fetchNpmDeps {
              # __contentAddressed = true;
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
      morphmcp = pkgs.buildNpmPackage rec {
        pname = "morphmcp";
        version = "0.8.165";

        src = pkgs.fetchurl {
          url = "https://registry.npmjs.org/@morphllm/${pname}/-/${pname}-${version}.tgz";
          hash = "sha256-njk7w+UG0b5icdgmYZQP2YImMFSkTgT34/3CLOsEO9o=";
        };

        sourceRoot = "package";

        postPatch = ''
          cp ${./morphmcp-package-lock.json} package-lock.json
        '';

        npmDepsHash = "sha256-NNNsDFaJDP0aC7LjqiJ4X0A/W8/4RvKyEDStnL5ROio=";

        makeCacheWritable = true;
        npm_config_ignore_scripts = "true";

        nativeBuildInputs = [ pkgs.makeWrapper ];

        postInstall = ''
          # Symlink ripgrep binary for @vscode/ripgrep
          mkdir -p $out/lib/node_modules/@morphllm/morphmcp/node_modules/@vscode/ripgrep/bin
          ln -s ${lib.getExe pkgs.ripgrep} $out/lib/node_modules/@morphllm/morphmcp/node_modules/@vscode/ripgrep/bin/rg
        '';

        dontBuild = true;
      };
      opencode =
        let
          latestRelease = builtins.fromJSON (builtins.readFile (builtins.fetchurl {
            url = "https://api.github.com/repos/anomalyco/opencode/releases/latest";
            name = "opencode-latest-release.json";
          }));
          tag = latestRelease.tag_name;
          version = lib.strings.removePrefix "v" tag;
          arch = if pkgs.stdenv.hostPlatform.isx86_64 then "x64" else "arm64";
        in
        inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.opencode.overrideAttrs (final: prev: {
          inherit version;
          src = builtins.fetchurl {
            url = "https://github.com/anomalyco/opencode/releases/download/${tag}/opencode-linux-${arch}.tar.gz";
            name = "opencode-${tag}.tar.gz";
          };
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
      config.lib.packages.gemini-cli
      # opencode
      pi-coding-agent
      config.lib.packages.opencode
      inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.omp
      # config.lib.packages.omp
      playwright-mcp
      mcp-nixos
      mcp-gateway
      context7-mcp
      # The rest
      ncdu
      sd
      atuin
      bat
      just
      jj-hunk
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
        pkgs.ty
        pkgs.vscode-langservers-extracted
        pkgs.yaml-language-server
      ];
    };
    programs.direnv.enable = true;
  };
}
