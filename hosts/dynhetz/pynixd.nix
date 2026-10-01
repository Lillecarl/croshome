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
    # `beside` while this is proven: pynixd listens on its own socket and only
    # a client that names it is affected. `replace` makes it the daemon every
    # client reaches, with nix-daemon moving to daemon-socket/upstream behind
    # it -- flip to that only once ai-rebuild-pynixd has built the system
    # through pynixd's socket.
    mode = "beside";
    package = nixidae.pynixd.package;
    settings = {
      log_level = "DEBUG";
      plugins = [ "/etc/pynixd/filter.py" ];
    };
  };
}
