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
inputs: final: prev:
let
  # Jool at 4.1.15 plus an unmerged upstream PR, because no released Jool
  # builds against this kernel.
  #
  # ../hosts/dynhetz/nat64.nix wants Jool for NAT64. nixpkgs ships 4.1.14, and
  # neither that nor 4.1.15 links against 7.2:
  #
  #   ERROR: modpost: "snmp_fold_field" [jool_common.ko] undefined!
  #
  # The kernel stopped exporting that symbol. NICMx/Jool#456, "stats: fix v7.2
  # loss of snmp_fold_field()", is the fix. It is still open, and it was opened
  # on 2026-08-11 -- months after 4.1.15 shipped -- so waiting for a release is
  # not an option that exists yet. It touches one file, src/mod/common/stats.c,
  # in two hunks.
  #
  # All three facts were checked by building, not by reading release notes:
  # 4.1.14 fails, 4.1.15 fails the same way, 4.1.15 with the PR succeeds.
  #
  # The patch is pinned by hash, so a force-push to that PR fails the fetch
  # loudly instead of quietly building something else.
  #
  # Drop this whole block when Jool releases a version carrying the fix.
  joolVersion = "4.1.15";

  joolSrc = final.fetchFromGitHub {
    owner = "NICMx";
    repo = "Jool";
    tag = "v${joolVersion}";
    hash = "sha256-I+cgxOONq8LZWlpVaqXW+MmEKts/dQAr7Hs8uC6N8/w=";
  };

  joolPr456 = final.fetchpatch {
    url = "https://github.com/NICMx/Jool/pull/456.patch";
    hash = "sha256-vYFZF0WFO6MNIj4cOdwmqV8UZsfOqrdLPP3E6dX9+q8=";
  };
in
{
  # The kernel module. `patches = [ ]` drops the Alpine kernel-6.18 patch
  # nixpkgs carries for 4.1.14: 4.1.15 already has those changes and the patch
  # no longer applies, which is how a plain version bump fails first.
  linuxPackages_latest = prev.linuxPackages_latest.extend (
    _: kprev: {
      jool = kprev.jool.overrideAttrs (_: {
        version = joolVersion;
        src = joolSrc;
        patches = [ joolPr456 ];
      });
    }
  );

  # The CLI, moved in lockstep. Jool's netlink protocol is versioned and the
  # tool refuses a module it does not match, so bumping one alone trades a
  # build failure for a runtime one.
  #
  # No `patches` override here: nixpkgs' own validate-config.patch adds the
  # `jool file check` subcommand that the NixOS module's build-time validation
  # runs, and it still applies to 4.1.15 -- checked by building it.
  jool-cli = prev.jool-cli.overrideAttrs (_: {
    version = joolVersion;
    src = joolSrc;
  });

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

  # The tmux-driven completion tests for the vendored anyxonsh, run by the
  # venv under test itself: libtmux is one of its Python dependencies, so no
  # second environment exists for tests alone. The script lives beside the
  # shell it exercises -- `pkgs/anyxonsh/tests/completions.py` -- and the
  # wrapper puts that same anyxonsh build on PATH for it to launch.
  #
  #   nix build --file . pkgs.anyxonsh-tests && ./result/bin/anyxonsh-tests
  #
  # tmux speaks neither the Kitty keyboard protocol nor its ANSI extensions,
  # so flows that depend on those need a pty and are out of scope here.
  anyxonsh-tests =
    final.runCommand "anyxonsh-tests"
      {
        nativeBuildInputs = [ final.makeWrapper ];
        meta.description = "tmux-driven completion tests for the vendored anyxonsh";
      } ''
      mkdir -p $out/bin
      makeWrapper ${final.anyxonsh.venv}/bin/python $out/bin/anyxonsh-tests \
        --add-flags "${./anyxonsh/tests/completions.py}" \
        --prefix PATH : ${final.anyxonsh}/bin
    '';

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
