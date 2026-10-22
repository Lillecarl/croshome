{
  config,
  lib,
  pkgs,
  selfStr,
  ...
}:

let
  cfg = config.programs.ai-rebuild;

  # Named ai-rebuild on every host, so an agent runs one command whichever
  # machine it is on.
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

  umbrellaBlock = lib.optionalString (cfg.umbrellaDev != null) ''
    # Read the umbrella's working copies live, the way ./overrides.nix
    # reads this repository's own inputs live. resolve.nix answers a source
    # with a checkout beside the umbrella as that directory when the
    # variable names it, and `all` names every one that is on disk; a
    # source with no checkout still comes from its lock. The pinned
    # `nixidae-pynixd` umbrella is a store path with no checkouts beside
    # it, so pynixd stays on its lock whatever this says.
    export UMBRELLA_DEV=${lib.escapeShellArg cfg.umbrellaDev}

  '';

  # One ai-rebuild at a time per machine: two concurrent switches race on the
  # system profile, and two builds of one toplevel do the work twice. The lock
  # is held until activation returns, so sudo runs as a child, not via exec.
  lockFile = "/run/ai-rebuild.lock";
  # tmpfiles creates the file at activation, so the first run after enabling
  # this finds none; it then runs unlocked rather than not at all.
  takeLock = ''
    if [ -e ${lockFile} ]; then
      exec 9<${lockFile}
      if ! flock --nonblock 9; then
        echo "ai-rebuild: waiting for another ai-rebuild to finish" >&2
        flock 9
      fi
    else
      echo "ai-rebuild: ${lockFile} missing, running without the lock" >&2
    fi
  '';

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

      ${lib.getExe' pkgs.nix "nix-env"} \
        -p /nix/var/nix/profiles/system --set "$toplevel"

      # switch-to-configuration restarts units, and a restarted unit takes its
      # process tree down with it. Upstream nixos-rebuild therefore runs the
      # switch from a transient systemd unit rather than from its own process;
      # the flags are its SWITCH_TO_CONFIGURATION_CMD_PREFIX, copied so this
      # detaches the same way.

      # nix 2.35's nix-env, which the systemd-boot builder runs on every
      # switch, opens the local store and asks the big-lock to upgrade to
      # exclusive, so it queues behind anything holding it shared -- a build,
      # a daemon connection -- and the switch hangs at the bootloader step.
      # Point root's Nix at a daemon socket instead: the lock then stays
      # inside the daemon and nix-env never opens the local store.
      #
      # The upstream socket on a replace host, because the default socket is
      # pynixd's and pynixd may be down or restarting mid-switch. Before the
      # first replace switch that socket does not exist yet, and the default
      # one is the daemon.
      if [ -S /nix/var/nix/daemon-socket/upstream ]; then
        NIX_REMOTE=unix:///nix/var/nix/daemon-socket/upstream
      else
        NIX_REMOTE=daemon
      fi

      export NIXOS_INSTALL_BOOTLOADER=0
      export NIX_REMOTE
      exec ${lib.getExe' pkgs.systemd "systemd-run"} \
        -E LOCALE_ARCHIVE \
        -E NIXOS_INSTALL_BOOTLOADER \
        -E NIXOS_NO_CHECK \
        -E NIX_REMOTE \
        --collect --no-ask-password --pipe --quiet --service-type=exec \
        --unit=nixos-rebuild-switch-to-configuration \
        "$toplevel/bin/switch-to-configuration" switch
    '';
  };

  ai-rebuild = pkgs.writeShellApplication {
    name = "ai-rebuild";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.util-linux
      config.nix.package
    ];
    text = ''
      # --upstream: build against nix-daemon behind pynixd, for when pynixd
      # misbehaves. The default socket is pynixd's on a replace host. The
      # activation step already prefers the upstream socket when it exists.
      # An exported NIX_REMOTE also passes through, so this is a shorthand.
      case "''${1:-}" in
        --upstream)
          export NIX_REMOTE=unix:///nix/var/nix/daemon-socket/upstream
          ;;
        "") ;;
        *)
          echo "usage: ai-rebuild [--upstream]" >&2
          exit 2
          ;;
      esac

      ${takeLock}
      ${umbrellaBlock}# Build as this user. stdout carries nothing but the store path; every
      # other line goes to stderr.
      #
      # `nix build`, not `nixos-rebuild build`: that runs nix-build, which
      # aborts on a floating content-addressed toplevel (Nix 2.35.3,
      # assertion 'maybeOutputPath', nix-build.cc:730).
      toplevel=$(nix build --no-link --print-out-paths \
        --file ${lib.escapeShellArg selfStr} ${lib.escapeShellArg "${cfg.attr}.config.system.build.toplevel"})

      # sudo comes from PATH on purpose: only the setuid wrapper in
      # /run/wrappers can elevate, a store-path sudo cannot.
      sudo -n /run/current-system/sw/bin/ai-rebuild-activate "$toplevel"
    '';
  };
  ai-rebuild-pynixd = pkgs.writeShellApplication {
    name = "ai-rebuild-pynixd";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.util-linux
      config.nix.package
    ];
    text = ''
      ${takeLock}
      toplevel=$(nix build --no-link --print-out-paths \
        --option eval-store unix:///nix/var/nix/daemon-socket/socket \
        --option store unix:///run/pynixd/pynixd.sock \
        --file ${lib.escapeShellArg selfStr} ${lib.escapeShellArg "${cfg.attr}.config.system.build.toplevel"})

      sudo -n /run/current-system/sw/bin/ai-rebuild-activate "$toplevel"
    '';
  };
in
{
  options.programs.ai-rebuild = {
    enable = lib.mkEnableOption "ai-rebuild, a user build plus one NOPASSWD activation step";
    attr = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "Attribute of the repository root that ai-rebuild builds.";
    };
    umbrellaDev = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "UMBRELLA_DEV for the build: which nixidae umbrella sources come from checkouts beside it.";
    };
    pynixdVariant.enable = lib.mkEnableOption "ai-rebuild-pynixd, the same switch built through the pynixd store";
    sudo = {
      users = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Users that may run ai-rebuild-activate without a password.";
      };
      groups = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Groups that may run ai-rebuild-activate without a password.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Read-only for callers: flock needs only an open descriptor.
    systemd.tmpfiles.rules = [ "f ${lockFile} 0444 root root -" ];

    environment.systemPackages = [
      ai-rebuild
      ai-rebuild-activate
    ]
    ++ lib.optional cfg.pynixdVariant.enable ai-rebuild-pynixd;

    # The stable path, not the store path: sudo compares the command as the
    # caller wrote it, so a rule naming a store path is only matched by someone
    # who typed that store path. `ai-rebuild` calls the helper by its absolute
    # /run/current-system/sw/bin path, which is where the rule looks.
    #
    security.sudo.extraRules = [
      {
        users = cfg.sudo.users;
        groups = cfg.sudo.groups;
        commands = [
          {
            command = "/run/current-system/sw/bin/ai-rebuild-activate";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];
  };
}
