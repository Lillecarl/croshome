{
  config,
  lib,
  pkgs,
  selfStr,
  ...
}:

let
  # Named ai-rebuild here and on the MacBook and on hetztop, so an agent runs
  # one command whichever machine it is on.
  #
  # Only two steps of a switch need root: pointing the system profile at the
  # new toplevel, and running switch-to-configuration. Everything before that
  # -- evaluation, fetching, building -- runs as the calling user, so it
  # shares the user's fetcher caches instead of repopulating root's on every
  # run. nixos-rebuild's own --sudo elevates exactly those two steps too, but
  # the commands it then hands to sudo carry dynamic store paths plus an
  # env/systemd-run argv shape that no sane sudoers rule can name. So the
  # script below builds as the user and hands one store path to
  # ai-rebuild-activate, which is the only thing the sudoers rule trusts.
  #
  # Read the grant as full root, not narrow root: the helper activates
  # whatever path it is given, and the caller chooses that path by evaluating
  # arbitrary Nix.

  ai-rebuild-activate = pkgs.writeShellApplication {
    name = "ai-rebuild-activate";
    text = ''
      # Runs as root under NOPASSWD. Takes one argument: the system toplevel.
      if [[ "$#" -ne 1 ]]; then
        echo "usage: ai-rebuild-activate <system-toplevel>" >&2
        exit 2
      fi

      toplevel=$1

      case $toplevel in
        /nix/store/*) ;;
        *)
          echo "ai-rebuild-activate: refusing a path outside /nix/store: $toplevel" >&2
          exit 2
          ;;
      esac

      # The same guard nixos-rebuild applies before touching the profile.
      test -f "$toplevel/nixos-version" || {
        echo "ai-rebuild-activate: $toplevel does not look like a NixOS toplevel" >&2
        exit 1
      }

      ${pkgs.nix}/bin/nix-env \
        -p /nix/var/nix/profiles/system --set "$toplevel"

      # switch-to-configuration restarts units, and a restarted unit takes its
      # process tree down with it. Upstream nixos-rebuild therefore runs the
      # switch from a transient systemd unit rather than from its own process;
      # the flags are its SWITCH_TO_CONFIGURATION_CMD_PREFIX, copied so this
      # detaches the same way.
      export NIXOS_INSTALL_BOOTLOADER=0
      exec ${pkgs.systemd}/bin/systemd-run \
        -E LOCALE_ARCHIVE \
        -E NIXOS_INSTALL_BOOTLOADER \
        -E NIXOS_NO_CHECK \
        --collect --no-ask-password --pipe --quiet --service-type=exec \
        --unit=nixos-rebuild-switch-to-configuration \
        "$toplevel/bin/switch-to-configuration" switch
    '';
  };

  ai-rebuild = pkgs.writeShellApplication {
    name = "ai-rebuild";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.nixos-rebuild
    ];
    text = ''
      # Build as this user. stdout carries nothing but the store path; every
      # other line goes to stderr.
      toplevel=$(nixos-rebuild build \
        --file ${lib.escapeShellArg selfStr} --attr dynhetz)

      # sudo comes from PATH on purpose: only the setuid wrapper in
      # /run/wrappers can elevate, a store-path sudo cannot.
      exec sudo -n /run/current-system/sw/bin/ai-rebuild-activate "$toplevel"
    '';
  };
in
{
  environment.systemPackages = [
    ai-rebuild
    ai-rebuild-activate
  ];

  # The stable path, not the store path: sudo compares the command as the
  # caller wrote it, so a rule naming a store path is only matched by someone
  # who typed that store path. `ai-rebuild` calls the helper by its absolute
  # /run/current-system/sw/bin path, which is where the rule looks.
  security.sudo.extraRules = [
    {
      users = [ "lillecarl" ];
      commands = [
        {
          command = "/run/current-system/sw/bin/ai-rebuild-activate";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];
}
