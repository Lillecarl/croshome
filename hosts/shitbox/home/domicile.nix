# Log in on tty2 and domicile takes the screen; niri keeps tty1. Exiting
# domicile logs out of tty2.
{ ... }:
{
  xdg.configFile."domicile/shell.js".source = ./domicile/shell.js;

  programs.fish.loginShellInit = ''
    if test "$XDG_VTNR" = 2
      domicile ~/.config/domicile/shell.js
      exit
    end
  '';
}
