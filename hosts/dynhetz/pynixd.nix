{
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
  # carries no `src`.
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
      log_level = "DEBUG";
      plugins = [ "/etc/pynixd/filter.py" ];
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
      };
    };
  };
}
