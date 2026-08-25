### `inputs` ahead of `final: prev:`, which one package below needs and the
### rest do not. Two consequences, neither obvious from the line itself:
###
###   * This overlay is no longer applicable to a bare nixpkgs. It closes over
###     ../flake.lock through `inputs`, so it belongs to this repository rather
###     than being a file that can be lifted out of it.
###   * It is applied by `pkgsFor` in ../default.nix, so every attribute here
###     exists on all three hosts -- cros included, which is otherwise kept
###     deliberately thin. Nix is lazy, so an attribute nothing references
###     costs nothing; `agenix` is referenced only by the two system hosts.
inputs: final: prev: {
  # The agenix CLI, for `agenix -e` and `agenix -r`. Built from the input
  # source tree rather than from nixpkgs, which has no `agenix` -- only
  # `ragenix`, a separate Rust reimplementation with its own file format
  # quirks. See ../flake.nix for why the input is `flake = false`.
  #
  # Here in the overlay and not inline in ../secrets/default.nix, so that
  # `nix run --file . pkgs.agenix` resolves without evaluating a host -- which
  # is what makes it reachable on a machine this configuration has never
  # activated. It is the same derivation either way: `callPackage` against
  # this package set, so it links the same `age` the module runs.
  agenix = final.callPackage "${inputs.agenix}/pkgs/agenix.nix" { };

  claude-code =
    let
      baseUrl = "https://downloads.claude.ai/claude-code-releases";
      version = final.lib.strings.trim (
        builtins.readFile (
          builtins.fetchurl {
            url = "${baseUrl}/latest";
            name = "claude-code-latest-version";
          }
        )
      );
      platformKey = "${final.stdenv.hostPlatform.node.platform}-${final.stdenv.hostPlatform.node.arch}";
    in
    prev.claude-code.overrideAttrs (_: {
      inherit version;
      src = builtins.fetchurl {
        url = "${baseUrl}/${version}/${platformKey}/claude";
      };
    });

  toad = final.python314.pkgs.callPackage ./toad.nix { };

  wrapty = final.python314.pkgs.callPackage ./wrapty { };

  # The xonsh bundle from Lillecarl/anyxonsh, vendored wholesale into
  # ./anyxonsh -- source tree and build machinery together, because the plan
  # is to iterate here rather than track upstream. Its nix/ directory bridges
  # Nixpkgs' Python package set into pyproject.nix's flat dependency resolver
  # (see that tree's nix/bridge.nix for why that exists); pyproject-nix comes
  # from the flake inputs, following this repository's nixpkgs.
  #
  # In the overlay rather than a host file so `nix run --file . pkgs.anyxonsh`
  # reaches it on a machine this configuration has never activated -- the same
  # reasoning agenix has.
  #
  # The arguments below are the upstream default shell, verbatim. mkAnyxonsh
  # is additive by design, so a later change here cannot silently lose one of
  # these.
  anyxonsh =
    let
      pyproject-nix = import inputs.pyproject-nix { inherit (final) lib; };
      bridge = final.callPackage ./anyxonsh/nix/bridge.nix { inherit pyproject-nix; };
      mkAnyxonsh = final.callPackage ./anyxonsh/nix/mk-anyxonsh.nix {
        pkgs = final;
        inherit pyproject-nix bridge;
      };
    in
    mkAnyxonsh.mkAnyxonsh {
      pythonPackages = ps: [
        ps.libtmux
        ps.requests
        ps.rich
      ];
      xontribs = xs: [
        xs.xontrib-vox
        xs.xontrib-abbrevs
        # Nixpkgs' own xontrib-jedi fails one of its tests against the jedi
        # version currently in nixpkgs -- `nix build` on the bare
        # `xonsh.passthru.xontribs.xontrib-jedi` attribute fails identically, so
        # this is upstream's bug, not the bridge's. Skip that single test rather
        # than dropping a useful completion xontrib.
        (xs.xontrib-jedi.overridePythonAttrs (old: {
          disabledTests = (old.disabledTests or [ ]) ++ [ "test_special_tokens" ];
        }))
      ];
      # Packages Nixpkgs doesn't ship, built with pyproject.nix directly. Named in
      # `extraPackages` so they become real dependency edges in the venv spec.
      overlays = [ (final.callPackage ./anyxonsh/nix/extra-packages.nix { }) ];
      extraPackages = [
        # From PyPI wheels
        "xontrib-term-integrations"
        "xontrib-cmd-durations"
        "xontrib-fish-completer"
        # Built from source: sdist tarball, and a git checkout
        "xontrib-output-search"
        "xontrib-fzf-widgets"
        "xontrib-envrc"
        # Built from source because it is patched -- see nix/extra-packages.nix.
        "xontrib-zoxide"
      ];

      paths = [
        # A stripped remote host inherits whatever PATH is already there, which
        # may not include a usable `ls`/`cat`/`env`. A shell that calls itself
        # complete brings its own.
        final.coreutils
        final.bat
        final.eza
        final.fd
        # xontrib-fzf-widgets shells out to `fzf`; nothing puts it on PATH for us
        # because nixpkgsPrebuilt discards wrapper scripts.
        final.fzf
        final.gitMinimal
        final.ripgrep
        # xontrib-zoxide shells out to `zoxide` -- it is a Rust binary, not a
        # Python dependency, so nothing in the venv would bring it along.
        final.zoxide
      ];
    };

  kagi-mcp = final.python3.pkgs.callPackage ./kagi-mcp { };

  jj-hunk = final.callPackage ./jj-hunk.nix { };

  # vfkit with the memory balloon reachable over its REST API. Darwin only: it
  # wraps Apple's Virtualization.framework and does not exist elsewhere, so
  # naming prev.vfkit unconditionally would break evaluation on the Linux hosts.
  vfkit =
    if prev.stdenv.hostPlatform.isDarwin then
      # `inherit (prev) vfkit` is required, not tidiness. callPackage resolves
      # its arguments against the *final* package set even when reached through
      # `prev`, so leaving it implicit feeds this override back into itself and
      # evaluation dies with infinite recursion.
      prev.callPackage ./vfkit-balloon.nix { inherit (prev) vfkit; }
    else
      prev.vfkit;

  foot = prev.foot.overrideAttrs (pattrs: {
    patches = pattrs.patches or [ ] ++ [
      ./0001-ignore-numlock.patch
    ];
  });

  tmux-unscroll = prev.tmux.overrideAttrs {
    src = /home/lillecarl/Code/tmux;
  };

  hetztop-forward =
    let
      sessionConfig = prev.writeText "tmuxp.yaml" (
        builtins.toJSON {
          session_name = "hetztop-forwards";
          windows = [
            {
              window_name = "scripts";
              layout = "even-vertical";
              panes = [
                {
                  shell_command = final.lib.getExe (
                    final.writeShellApplication {
                      name = "hetztop-waypipe";
                      runtimeInputs = [
                        final.coreutils
                        final.openssh
                        final.waypipe
                      ];
                      text = # bash
                        ''
                          set -x

                          delay=1
                          max_delay=600  # 10 minutes

                          while true; do
                              if waypipe --unlink-socket --compress zstd --display wayland-1 --no-gpu ssh lillecarl@65.108.150.98; then
                                  delay=1
                                  sleep "$delay"
                              else
                                  echo "Failed, waiting ''${delay}s"
                                  sleep "$delay"
                                  delay=$((delay * 2))
                                  if [ "$delay" -gt "$max_delay" ]; then
                                      delay=$max_delay
                                  fi
                              fi
                          done
                        '';
                    }
                  );
                }
                {
                  shell_command = final.lib.getExe (
                    final.writeShellApplication {
                      name = "hetztop-ports";
                      runtimeInputs = [
                        final.coreutils
                        final.openssh
                        final.waypipe
                      ];
                      text = # bash
                        ''
                          set -x

                          delay=1
                          max_delay=600  # 10 minutes

                          while true; do
                              if ssh -L 8000:localhost:8000 lillecarl@65.108.150.98; then
                                  delay=1
                                  sleep "$delay"
                              else
                                  echo "Failed, waiting ''${delay}s"
                                  sleep "$delay"
                                  delay=$((delay * 2))
                                  if [ "$delay" -gt "$max_delay" ]; then
                                      delay=$max_delay
                                  fi
                              fi
                          done
                        '';
                    }
                  );
                }
              ];
            }
          ];
        }
      );
    in
    final.writeShellApplication {
      name = "hetztop-forwards";
      runtimeInputs = [
        final.tmuxp
      ];
      text = # bash
        ''
          set -euo pipefail
          tmuxp load ${sessionConfig}
        '';
    };
}
