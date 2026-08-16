final: prev: {
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
