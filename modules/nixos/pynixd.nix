{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:
let
  # The pinned umbrella resolves pynixd from its own nix/sources.lock, so
  # the revision is the one `nixidae-pynixd` pins and no separate pynixd
  # input exists. It never names a path in overrides.nix: a rebuild that
  # changes pynixd restarts the system daemon and cancels every running build.
  nixidaePynixd = import inputs.nixidae-pynixd { inherit pkgs; };
in
{
  # `.sources` reads the lock and needs no package set, which is what keeps
  # it safe to name in `imports`.
  imports = [
    ((import inputs.nixidae-pynixd { }).sources.pynixd + "/nix/nixos")
  ];

  config = lib.mkMerge [
    {
      # The filter comes from the pynixd source tree, and not from
      # `services.pynixd.package.src`: the package is an `mkApp` result and
      # carries no `src`. It drops noisy info events that would otherwise be
      # written on every store operation.
      environment.etc."pynixd/filter.py".source =
        nixidaePynixd.sources.pynixd + "/pynixd/filters/scheduler_focus.py";

      # The module states no default for `package` -- only `nixosModules.pynixd`
      # in pynixd's own flake does, and this imports the module file directly.
      services.pynixd.package = lib.mkDefault nixidaePynixd.pynixd.package;
    }

    (lib.mkIf config.services.pynixd.enable {
      # The daemon reads its JSON once at startup, so a settings change that
      # leaves the unit file untouched never reaches the running process: the
      # switch activates the file and the old daemon keeps serving. Naming the
      # rendered config as a restart trigger changes the unit with it, and the
      # switch restarts the daemon. ai-rebuild then activates end to end, with
      # no hand step after it.
      systemd.services.pynixd.restartTriggers = [
        config.environment.etc."pynixd/pynixd.json".source
      ];
    })

    (lib.mkIf config.services.pynixd.enable {
      # Home-manager activation shells out to nix, which talks to the daemon
      # socket this module replaces. Its unit orders itself after
      # nix-daemon.socket, which `replace` mode masks, so nothing holds its
      # restart behind this socket coming back up: every switch bounces pynixd
      # and the first activation attempt lands on a dead socket ("Connection
      # refused", failed switch, retry minutes later). Order it behind the real
      # socket instead; connections then queue in the listen backlog while
      # pynixd restarts instead of refusing.
      systemd.services = lib.mapAttrs' (
        user: _:
        lib.nameValuePair "home-manager-${user}" {
          after = [ "pynixd.socket" ];
          wants = [ "pynixd.socket" ];
        }
      ) (config.home-manager.users or { });
    })
  ];
}
