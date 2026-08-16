{
  config,
  lib,
  pkgs,
  selfStr,
  ...
}:
let
  user = config.system.primaryUser;

  # The same three steps ../../rebuild takes for `switch`, in one command an
  # agent can run without a password. Deliberately argument-free: the sudoers
  # rule only matches an invocation with no arguments, so there is nothing to
  # pass that changes what gets built or where from.
  ai-rebuild = pkgs.writeShellApplication {
    name = "ai-rebuild";
    runtimeInputs = [
      config.nix.package
      pkgs.coreutils
      pkgs.nvd
    ];
    text = ''
      repo=${lib.escapeShellArg selfStr}
      profile=/nix/var/nix/profiles/system

      echo "building macbook from $repo..." >&2
      system=$(nix-build "$repo" --attr macbook.system --no-out-link)

      if [ "$(readlink -f /run/current-system)" = "$(readlink -f "$system")" ]; then
        echo "no change: the built system is the running one" >&2
        exit 0
      fi

      # An activation should be a decision, and an agent that cannot see what
      # moved cannot make one. It also leaves the diff in the transcript.
      nvd diff /run/current-system "$system" || true

      # Registering the generation is what makes `../../rebuild rollback` work.
      nix-env -p "$profile" --set "$system"
      "$system/activate"
    '';
  };
in
{
  environment.systemPackages = [ ai-rebuild ];

  # The stable path, not the store path, matching hetztop's rules: sudo
  # compares the command as the caller wrote it. Only activation can change
  # where it points, and that is root already. The trailing "" restricts the
  # rule to an invocation with no arguments at all.
  security.sudo.extraConfig = ''

    # Lets an agent apply a configuration change without a password prompt.
    ${user} ALL=(root) NOPASSWD: /run/current-system/sw/bin/ai-rebuild ""

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
