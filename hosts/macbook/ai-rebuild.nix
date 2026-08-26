{
  config,
  lib,
  pkgs,
  selfStr,
  ...
}:
let
  user = config.system.primaryUser;

  # Named ai-rebuild here and on hetztop, so an agent runs one command whichever
  # machine it is on. The repo path comes from selfStr rather than being written
  # out, so a moved checkout cannot leave this pointing at a stale tree.
  #
  # Only two steps of a switch need root: pointing the system profile at the new
  # toplevel, and running its activate script. Everything before that --
  # evaluation, fetching, building -- runs as the calling user, so it shares the
  # user's fetcher caches instead of repopulating root's on every run. There is
  # no nixos-rebuild-style --sudo to lean on here: darwin-rebuild refuses to run
  # unprivileged for a switch at all, which is precisely the whole-run-as-root
  # behaviour this avoids. So ai-rebuild below builds with nix-build itself and
  # hands one store path to ai-rebuild-activate, the only command the sudoers
  # rule trusts.
  #
  # Read the grant as full root, not narrow root, exactly as on hetztop: the
  # helper activates whatever path it is given, and the caller chooses that path
  # by evaluating arbitrary Nix.
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

      # The marker file every nix-darwin toplevel carries. This stands in for
      # the nixos-version check hetztop's helper makes before touching the
      # profile; upstream darwin-rebuild applies no equivalent guard itself.
      test -f "$toplevel/darwin-version" || {
        echo "ai-rebuild-activate: $toplevel does not look like a nix-darwin toplevel" >&2
        exit 1
      }

      # Both copied from darwin-rebuild itself: go through the daemon even as
      # root, so resource limits, TLS and proxy configuration apply, and take
      # root's HOME because macOS sudo preserves the caller's, which Nix warns
      # about.
      export NIX_REMOTE=daemon
      export HOME=~root

      # Registering the generation is what makes `../../rebuild rollback` work.
      ${config.nix.package}/bin/nix-env \
        -p /nix/var/nix/profiles/system --set "$toplevel"

      # The pinned nix-darwin has folded all activation back into this one
      # script, run as root; its activate-user is a deprecated stub that
      # darwin-rebuild skips, so there is no second half to run.
      exec "$toplevel/activate"
    '';
  };

  ai-rebuild = pkgs.writeShellApplication {
    name = "ai-rebuild";
    runtimeInputs = [
      config.nix.package
      pkgs.coreutils
      pkgs.nvd
    ];
    text = ''
      repo=${lib.escapeShellArg selfStr}

      echo "building macbook from $repo..." >&2
      system=$(nix-build "$repo" --attr macbook.system --no-out-link)

      if [ "$(readlink -f /run/current-system)" = "$(readlink -f "$system")" ]; then
        echo "no change: the built system is the running one" >&2
        exit 0
      fi

      # An activation should be a decision, and an agent that cannot see what
      # moved cannot make one. It also leaves the diff in the transcript.
      nvd diff /run/current-system "$system" || true

      # sudo comes from PATH on purpose, as on hetztop: elevation goes through
      # the setuid binary the system provides, and the NOPASSWD rule names the
      # helper by its absolute /run/current-system/sw/bin path, which is where
      # the rule looks -- sudo compares the command as the caller wrote it, so
      # a rule naming a store path would only match someone who typed it.
      exec sudo -n /run/current-system/sw/bin/ai-rebuild-activate "$system"
    '';
  };
in
{
  environment.systemPackages = [
    ai-rebuild
    ai-rebuild-activate
  ];

  # The stable path, not the store path, matching hetztop's rules. Unlike the
  # grant this replaces, the rule does not restrict arguments: the helper takes
  # exactly one and validates it, which a sudoers rule cannot express more
  # tightly than the helper can enforce anyway.
  security.sudo.extraConfig = ''

    # Lets an agent apply a configuration change without a password prompt.
    ${user} ALL=(root) NOPASSWD: /run/current-system/sw/bin/ai-rebuild-activate

    # Reading how much memory a process uses now needs root. macOS 26 gates
    # per-process memory behind an entitlement, and not only for other users'
    # processes -- `ps -o rss= -p $$` on your own shell answers
    # "ps: rss: requires entitlement". footprint and top refuse the same way,
    # and vmmap prints nothing. There is no unprivileged way left to ask.
    #
    # Both are read-only reporting tools, and neither reveals anything a root
    # shell would not. This restores a measurement that used to need no
    # privilege at all.
    ${user} ALL=(root) NOPASSWD: /bin/ps
    ${user} ALL=(root) NOPASSWD: /usr/bin/footprint

  '';
}
