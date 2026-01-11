final: prev: {
  foot = prev.foot.overrideAttrs (pattrs: {
    patches = pattrs.patches or [ ] ++ [
      ./0001-ignore-numlock.patch
    ];
  });

  tmux-unscroll = prev.tmux.overrideAttrs {
    src = /home/lillecarl/Code/tmux;
  };

  mosh = prev.mosh.overrideAttrs (pa: {
    src = builtins.fetchTree {
      type = "github";
      owner = "mobile-shell";
      repo = "mosh";
      ref = "master";
    };
    patches = [
      "${prev.path}/pkgs/by-name/mo/mosh/ssh_path.patch"
      "${prev.path}/pkgs/by-name/mo/mosh/mosh-client_path.patch"
      "${prev.path}/pkgs/by-name/mo/mosh/bash_completion_datadir.patch"
      (builtins.fetchurl "https://patch-diff.githubusercontent.com/raw/mobile-shell/mosh/pull/1367.patch")
    ];
  });

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
