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
      # `, <program> [args...]` runs a program from the pinned nixpkgs without
      # installing it -- comma, minus nix-index. The nixpkgs input is the channel
      # tarball, and that ships `programs.sqlite`: the binary-name -> attribute
      # index `command-not-found` already reads. Upstream comma shells out to
      # `nix-locate` and would want a second database built or downloaded; this
      # needs neither, and it resolves against the same tree the lookup came from,
      # so the attribute a name maps to is the one that gets run.
      comma = pkgs.writeShellApplication {
        name = ",";
        runtimeInputs = [
          pkgs.sqlite
          pkgs.nix
        ];
        text = ''
          if [ "$#" -eq 0 ]; then
            echo "usage: , <program> [args...]" >&2
            exit 2
          fi
          prog=$1
          shift

          # The name is interpolated into SQL below, so allow only the characters
          # a program name is actually made of.
          case $prog in
            *[!A-Za-z0-9._+-]*)
              echo ",: refusing a program name with unexpected characters: $prog" >&2
              exit 2
              ;;
          esac

          # Several packages can carry the same binary. Prefer the one whose
          # attribute *is* the program name, then the shortest -- `sqlite3` should
          # find `sqlite`, not something that happens to bundle a copy.
          attr=$(sqlite3 -readonly "${inputs.nixpkgs}/programs.sqlite" "
            select package from Programs
            where name = '$prog' and system = '${pkgs.stdenv.hostPlatform.system}'
            order by package = '$prog' desc, length(package) asc
            limit 1
          ")

          if [ -z "$attr" ]; then
            echo ",: nothing in the pinned nixpkgs provides '$prog'" >&2
            exit 127
          fi

          echo ",: $prog -> $attr" >&2
          exec nix run --file "${inputs.nixpkgs}" "$attr" -- "$@"
        '';
      };

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
      # Tooling an agent can actually drive: non-interactive, parseable output,
      # and interfaces stable enough to be known rather than guessed at. The TUIs
      # further up this list -- yazi, gitui, lazygit, k9s -- are the opposite, and
      # they are here for a human.
      config.lib.packages.comma
      sqlite # query any .db directly instead of writing a script around it
      ast-grep # structural search and rewrite, where ripgrep only sees text
      jc # turns the output of ~100 classic commands into JSON
      gron # JSON to greppable lines and back, for when the shape is unknown
      yq-go # jq syntax over YAML, TOML and XML
      shellcheck # check a shell script before it is the thing that ran
      shfmt
      difftastic # diff by syntax, so a reformat stops looking like a rewrite
      tree
      # Nix diagnostics, for a machine that rebuilds this much.
      nix-diff # what actually differs between two derivations, and so why it rebuilt
      nvd # package version diff between two generations
      statix
      deadnix
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
