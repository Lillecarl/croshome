{ ... }:
{
  imports = [
    ./kitty.nix
  ];

  # No XDG_RUNTIME_DIR exists on macOS: the spec makes it the login manager's
  # job and launchd has no equivalent hook. $TMPDIR is launchd's per-user
  # directory (0700, machine-local), so a subdirectory of it has the right
  # properties and keeps sockets out of general temp churn.
  #
  # It has to be Cocoa-Way's own directory rather than a generic one: the
  # compositor ignores an inherited XDG_RUNTIME_DIR and always binds its socket
  # in `std::env::temp_dir()/cocoa-way` (main.rs), so pointing anywhere else
  # leaves waypipe connecting to a path that does not exist.
  home.sessionVariables.XDG_RUNTIME_DIR = "$TMPDIR/cocoa-way";

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
