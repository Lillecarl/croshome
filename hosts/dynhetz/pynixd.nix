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

  services.pynixd = {
    enable = true;
    # `replace`: pynixd takes /nix/var/nix/daemon-socket/socket and nix-daemon
    # moves to daemon-socket/upstream behind it, so every client reaches
    # pynixd. Proven in `beside` first -- ai-rebuild-pynixd built the system
    # through its socket. If pynixd misbehaves, the real daemon is still on
    # that upstream socket:
    #   nix --store unix:///nix/var/nix/daemon-socket/upstream ...
    #
    # Entering this mode is a hand step after the switch: switch-to-configuration
    # does not restart socket units, so nix-daemon.socket keeps its old
    # ListenStream until it is restarted, and nix-daemon.service has to stop
    # first or it starts as a plain service and grabs the default socket that
    # pynixd wants. A reboot does both in the right order.
    mode = "replace";
    package = nixidae.pynixd.package;
    settings = {
      log_level = "DEBUG";
      plugins = [ "/etc/pynixd/filter.py" ];
    };
  };
}
