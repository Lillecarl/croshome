{
  config,
  lib,
  pkgs,
  ...
}:
let
  user = config.system.primaryUser;

  # The caller is root in the system domain, which has no window server to draw
  # on, so the dialog has to be handed to the user's Aqua session. It is
  # deliberately best-effort: nobody may be logged in yet, and a splash screen
  # is never worth failing activation over.
  announce = pkgs.writeShellScript "cande-announce" ''
    set -u
    generation="''${1:-unknown}"
    uid=$(id -u -- ${user} 2>/dev/null) || exit 0
    launchctl asuser "$uid" sudo --user=${user} -- /usr/bin/osascript \
      -e "display dialog \"Boot complete -- $generation\" with title \"nix-darwin\" buttons {\"OK\"} default button \"OK\" giving up after 4" \
      >/dev/null 2>&1 || true
  '';
in
{
  # Only at boot, where launchd decides the order and there is otherwise no
  # signal that everything has been applied. A switch is run interactively and
  # already tells you when it is done.
  launchd.daemons.activate-system.script = lib.mkAfter ''
    ${announce} "$(basename "$systemConfig")"
  '';
}
