# Log in on tty2 and domicile takes the screen; niri keeps tty1. Exiting
# domicile logs out of tty2.
{ pkgs, ... }:
{
  xdg.configFile."domicile/shell.js".source = ./domicile/shell.js;

  # Without an icon theme domicile looks icons up in hicolor only, where
  # tray icons named from a full theme (udiskie's) do not exist. catppuccin
  # installs Papirus (catppuccin-papirus-folders).
  xdg.configFile."domicile/domicile.json".text = builtins.toJSON {
    theme.icon_theme = "Papirus-Dark";
    extensions.web_store = [
      "nngceckbapebfimnlniiiahkandclblb" # Bitwarden
      "mlomiejdfkolichcflejclcbmpeaniij" # Ghostery
    ];
    # Once per session. A shell's own start hook reruns on every load-shell.
    startup.commands = [ [ "kitty" ] ];
  };

  home.packages = [
    # SIGTERM ends domicile cleanly. Its control socket is
    # domicile-ipc.<launcher pid>.sock, and every app it starts has it.
    (pkgs.writeShellScriptBin "domicile-quit" ''
      pid=''${DOMICILE_SOCK##*/domicile-ipc.}
      pid=''${pid%.sock}
      case $pid in
        "" | *[!0-9]*) echo "domicile-quit: no domicile in DOMICILE_SOCK='$DOMICILE_SOCK'" >&2; exit 1 ;;
      esac
      exec kill -TERM "$pid"
    '')
  ];

  # The Svelte shell from its checkout while it is developed there
  # (`bun run build` in ~/Code/domicile-svelte); this repository's
  # bootstrap shell when it is not built.
  programs.fish.loginShellInit = ''
    if test "$XDG_VTNR" = 2
      set -l shell ~/Code/domicile-svelte/shell/dist/shell.js
      test -f $shell; or set shell ~/.config/domicile/shell.js
      domicile $shell
      exit
    end
  '';
}
