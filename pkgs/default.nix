self: pkgs: {
  foot = pkgs.foot.overrideAttrs (pattrs: {
    patches = pattrs.patches or [ ] ++ [
      ./0001-ignore-numlock.patch
    ];
  });

  autowaypipe = self.writeShellApplication {
    name = "autowaypipe";
    runtimeInputs = [
      self.coreutils
      self.openssh
      self.waypipe
    ];
    text = # bash
      ''
        set -euo pipefail

        delay=1
        max_delay=600  # 10 minutes

        while true; do
            if waypipe --compress zstd --display wayland-1 --no-gpu ssh lillecarl@65.108.150.98; then
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
  };
}
