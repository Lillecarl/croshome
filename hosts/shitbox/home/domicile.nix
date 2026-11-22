# Log in on tty2 and domicile takes the screen; niri keeps tty1. Exiting
# domicile logs out of tty2.
{ pkgs, ... }:
{
  xdg.configFile."domicile/shell.js".source = ./domicile/shell.js;

  # SIGTERM ends domicile cleanly. Its control socket is
  # domicile-ipc.<launcher pid>.sock, and every app it starts has it.
  home.packages = [
    (pkgs.writeShellScriptBin "domicile-quit" ''
      pid=''${DOMICILE_SOCK##*/domicile-ipc.}
      pid=''${pid%.sock}
      case $pid in
        "" | *[!0-9]*) echo "domicile-quit: no domicile in DOMICILE_SOCK='$DOMICILE_SOCK'" >&2; exit 1 ;;
      esac
      exec kill -TERM "$pid"
    '')
  ];

  programs.fish.loginShellInit = ''
    if test "$XDG_VTNR" = 2
      domicile ~/.config/domicile/shell.js
      exit
    end
  '';
}
