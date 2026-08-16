{
  config,
  pkgs,
  lib,
  inputs,
  platform,
  system,
  ...
}:
{
  lib.packages = {
    # `, <program> [args...]` runs a program from the pinned nixpkgs without
    # installing it -- comma, minus nix-index. The nixpkgs input is the channel
    # tarball, and that ships `programs.sqlite`: the binary-name -> attribute
    # index `command-not-found` already reads. Upstream comma shells out to
    # `nix-locate` and would want a second database built or downloaded; this
    # needs neither, and it resolves against the same tree the lookup came from,
    # so the attribute a name maps to is the one that gets run.
    comma =
      let
        # The table only has Linux rows -- the channel builds the index on
        # Linux -- so on macOS there is nothing to match and every lookup would
        # come back empty. What is being looked up is which attribute carries a
        # binary of this name, and that mapping is not platform specific, so
        # query the Linux rows and run the result from the local package set.
        # The cost is that a Linux-only package can be suggested here; it then
        # fails to build, which is a clearer answer than "nothing provides it".
        indexSystem = if platform.isLinux then system else "aarch64-linux";
      in
      pkgs.writeShellApplication {
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
            where name = '$prog' and system = '${indexSystem}'
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
  };

  home.packages = with pkgs; [
    # Version control and code
    ast-grep # structural search and rewrite, where ripgrep only sees text
    binutils
    difftastic # diff by syntax, so a reformat stops looking like a rewrite
    gitui
    jj-hunk
    lazygit
    shellcheck # check a shell script before it is the thing that ran
    shfmt
    tree

    # Nix
    deadnix
    nixd
    nixfmt
    statix

    # `import`, and not a flake output: nanopynix is a `flake = false` input,
    # so this reads its `default.nix` and no flake of it is evaluated. That
    # file takes the package set that builds it, and this one carries the
    # overlays of this configuration, so there is no second nixpkgs.
    #
    # macOS needs a nanopynix newer than the lock. Until Lillecarl/nanopynix#148
    # reaches develop, this machine gets it from ../overrides.nix -- so a macOS
    # clone without that file stops here, on nanopynix-store-exec being
    # lib.platforms.linux. Linux builds from the lock and needs nothing.
    (import "${inputs.nanopynix}" { inherit pkgs; }).pynix
    # Nix diagnostics, for machines that rebuild this much. ../../rebuild uses
    # both: nvd lists the packages a switch would move, nix-diff says why a
    # derivation differs when no version moved at all.
    nix-diff
    nvd

    # Kubernetes
    kubectl
    kubectl-explore
    kubectx
    stern

    # Shell and text tooling an agent can actually drive: non-interactive,
    # parseable output, and interfaces stable enough to be known rather than
    # guessed at. The TUIs above -- yazi, gitui, lazygit, k9s -- are the
    # opposite, and they are here for a human.
    config.lib.packages.comma
    gron # JSON to greppable lines and back, for when the shape is unknown
    jc # turns the output of ~100 classic commands into JSON
    sqlite # query any .db directly instead of writing a script around it
    yq-go # jq syntax over YAML, TOML and XML

    # Software bill of materials for a closure. The dfdiskcache patch is a
    # dependency whose requirements pin pandas below 3, which nixpkgs has moved
    # past; the runtime check is what fails on it, not the code.
    (
      let
        patchedPython = pkgs.python3.override {
          packageOverrides = self: super: {
            dfdiskcache = super.dfdiskcache.overrideAttrs (old: {
              pythonRuntimeDepsCheck = false;
              postPatch = (old.postPatch or "") + ''
                substituteInPlace requirements/requirements.txt --replace "pandas>=1,<3" "pandas>=1"
              '';
            });
          };
        };
      in
      sbomnix.override { python3 = patchedPython; }
    )

    # The rest
    atuin
    fish-lsp
    wireguard-tools
    fzf
    just
    mosh
    ncdu
    rclone
    sd
    sshuttle
    taskwarrior3
    viddy
  ];
}
