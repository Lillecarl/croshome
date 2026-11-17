# shitbox's graphical session, ported from ~/Code/nixos users/lillecarl/gui.
# niri plus the user services it starts. ../contract.nix pins the generated
# config.kdl and the service list, so a change here shows up in
# ../check-contract before it reaches the session.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [
    ./avizo.nix
    ./cliphist.nix
    ./kitty.nix
    ./niri.nix
    ./rofi.nix
    ./swaybg.nix
    ./swayidlelock.nix
    ./swaync.nix
    ./udiskie.nix
    ./waybar.nix
  ];

  # Log in on tty1 and the session starts: the login environment goes to a
  # file niri.service reads (below), then fish waits on the unit and logs out
  # when niri exits.
  programs.fish.loginShellInit = ''
    if test "$XDG_VTNR" = 1
      systemctl --user stop graphical-session.target
      env | string match --invert --regex '^SHLVL=' >$XDG_RUNTIME_DIR/nirienv
      systemctl --user --wait start niri
      exit
    end
  '';
  xdg.configFile."systemd/user/niri.service.d/override.conf".text = ''
    [Service]
    EnvironmentFile=%t/nirienv
  '';

  home.packages = with pkgs; [
    firefox
    ddcutil # niri switches the right monitor's input at startup
    wl-clipboard
    pulsemixer # waybar's volume click
    pavucontrol
    swaynotificationcenter
  ];

  gtk = {
    enable = true;
    theme.name = "adw-gtk3-dark";
    theme.package = pkgs.adw-gtk3;
    gtk4.theme = config.gtk.theme;
  };
  home.pointerCursor = {
    enable = true;
    name = "catppuccin-mocha-blue-cursors";
    package = pkgs.catppuccin-cursors.mochaBlue;
    gtk.enable = true;
  };
}
