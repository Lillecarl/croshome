{
  config,
  pkgs,
  inputs,
  ...
}:
let
  # The umbrella resolves pynixd from its own nix/sources.lock, so the
  # revision is the one nixidae pins and no separate pynixd input exists.
  nixidae = import inputs.nixidae { inherit pkgs; };
in
{
  # The filter comes from the pynixd source tree, and not from
  # `services.pynixd.package.src`: the package is an `mkApp` result and
  # carries no `src`. It drops noisy info events that would otherwise be
  # written on every store operation.
  environment.etc."pynixd/filter.py".source =
    nixidae.sources.pynixd + "/pynixd/filters/scheduler_focus.py";

  # Nix 2.35 names the socket-activated descriptor `nix-daemon.socket` in
  # LISTEN_FDNAMES, and the upstream socket unit pynixd listens behind relies
  # on that name. Under 2.34 the socket activates on nothing and every client
  # hangs, so `replace` needs this version.
  nix.package = pkgs.nixVersions.latest;

  services.pynixd = {
    enable = true;
    # `replace`: pynixd takes /nix/var/nix/daemon-socket/socket and nix-daemon
    # moves behind it as nix-daemon-upstream.socket/.service, so every client
    # reaches pynixd. nix-daemon still runs the builds; pynixd only proxies.
    # The module masks Nix's own two units, so switch-to-configuration moves
    # the sockets in both directions with no hand step.
    #
    # If pynixd misbehaves, the real daemon is still on the upstream socket:
    #   nix --store unix:///nix/var/nix/daemon-socket/upstream ...
    mode = "replace";
    package = nixidae.pynixd.package;
    settings = {
      log_level = "INFO";
      plugins = [ "/etc/pynixd/filter.py" ];
      # Dry-run phase for age-based GC: the hourly EXECUTE loop stays off,
      # and collection runs only by hand (`pynixd gc`, `--execute` to delete).
      # Flip back on once the dry-run plans look right.
      gc_enabled = false;
      # A store gets a build scheduled to it only when it has a feature
      # matrix. With none, pynixd probes the daemon with test builds at
      # startup and, until that finishes, refuses every build with "no
      # feature_matrix (not probed)". On a busy store the probe also overruns
      # systemd's start timeout, so pynixd never reaches READY at all.
      # Declaring the matrix gives the local store one outright: scheduled,
      # and no probe. Features mirror nix.settings.system-features on this
      # host (./default.nix).
      stores.local = {
        systems = [ "x86_64-linux" ];
        system_features = [
          "nixos-test"
          "benchmark"
          "big-parallel"
          "kvm"
          "uid-range"
        ];
        # Dead and unreferenced for 7 days may be collected. The tracker
        # only learned references when pynixd started writing access rows,
        # so a young tracker plans little: that is the safe direction, and
        # the dry-run says how little.
        gc_max_age = 604800;
      };
    };
  };

  # The daemon reads its JSON once at startup, so a settings change that
  # leaves the unit file untouched never reaches the running process: the
  # switch activates the file and the old daemon keeps serving. Naming the
  # rendered config as a restart trigger changes the unit with it, and the
  # switch restarts the daemon. ai-rebuild then activates end to end, with
  # no hand step after it.
  systemd.services.pynixd.restartTriggers = [
    config.environment.etc."pynixd/pynixd.json".source
  ];
}
