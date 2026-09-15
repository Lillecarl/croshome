{ ... }:
{
  imports = [
    ./flush-dns.nix
    ./kitty.nix
  ];

  # No XDG_RUNTIME_DIR exists on macOS: the spec makes it the login manager's
  # job and launchd has no equivalent hook. $TMPDIR is launchd's per-user
  # directory (0700, machine-local), so a subdirectory of it has the right
  # properties. ask, ocahub and wrapty bind their sockets in subdirectories of
  # it; without the variable they fall back to a /run/user that macOS does not
  # have, or to the shared /tmp. A subdirectory rather than $TMPDIR itself, so
  # a program that assumes it owns XDG_RUNTIME_DIR stays inside it.
  home.sessionVariables.XDG_RUNTIME_DIR = "$TMPDIR/run";

  # config.fish sources the session variables before running shellInit, so
  # XDG_RUNTIME_DIR is already set here. Nothing creates it -- macOS has no
  # pam_systemd -- and the spec wants it user-private.
  programs.fish.shellInit = ''
    test -d "$XDG_RUNTIME_DIR"; or mkdir -m 700 -p "$XDG_RUNTIME_DIR"
  '';

  # fish's generateCompletions turns this on, but macOS ships its own man and
  # home-manager leaves programs.man.package null here, so it cannot work.
  programs.man.generateCaches = false;
}
