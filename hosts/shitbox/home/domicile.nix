# Log in on tty2 and domicile takes the screen; niri keeps tty1. Exiting
# domicile logs out of tty2.
{ lib, pkgs, ... }:
let
  # Sites as apps: a window of their own with no address bar, in a browser
  # profile, raised rather than opened again (docs/architecture/WEB-APPS.md
  # in domicile). Icons are Papirus names.
  webApps = {
    slack-work = {
      name = "Slack (Work)";
      url = "https://dynamist.slack.com/";
      profile = "work";
      icon = "slack";
    };
    gmail-work = {
      name = "Gmail (Work)";
      url = "https://mail.google.com/";
      profile = "work";
      icon = "gmail";
    };
    calendar-work = {
      name = "Google Calendar (Work)";
      url = "https://calendar.google.com/";
      profile = "work";
      icon = "calendar";
    };
    messenger = {
      name = "Messenger";
      url = "https://www.messenger.com/";
      profile = "personal";
      icon = "caprine";
    };
    element = {
      name = "Element";
      url = "https://app.element.io/";
      profile = "personal";
      icon = "element";
    };
    migadu = {
      name = "Migadu";
      url = "https://webmail.migadu.com/";
      profile = "personal";
      icon = "mail-client";
    };
    gmail-personal = {
      name = "Gmail (Personal)";
      url = "https://mail.google.com/";
      profile = "personal";
      icon = "gmail";
    };
    discord = {
      name = "Discord";
      url = "https://discord.com/app";
      profile = "personal";
      icon = "discord";
    };
  };
in
{
  xdg.desktopEntries = lib.mapAttrs (id: app: {
    inherit (app) name icon;
    exec = "domicile open --app --profile ${app.profile} --id ${id} --reuse focus ${app.url}";
    categories = [ "Network" ];
  }) webApps;

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
    # Vim scrolling and link hints, from its checkout.
    extensions.unpacked = [ "~/Code/domicile-svelte/extensions/pagekeys" ];
    # Once per session. A shell's own start hook reruns on every load-shell.
    startup.commands = [ [ "kitty" ] ];
    # Each profile has its own sign-ins, site data and extensions. The default
    # is the profile browsing always used, so its sign-ins stay.
    browser = {
      profiles = {
        personal = {
          name = "Personal";
          color = "#0d9488";
        };
        work = {
          name = "Work";
          color = "#d97706";
        };
        private = {
          name = "Private";
          color = "#a78bfa";
          private = true;
        };
      };
      order = [
        "personal"
        "work"
        "private"
      ];
      default_profile = "personal";
      default_private_profile = "private";
      sites."dynamist.slack.com" = "work";
    };
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
