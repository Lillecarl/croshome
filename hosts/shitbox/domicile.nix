# Domicile, a Wayland desktop whose compositor is Chromium. Runs on tty2
# beside niri on tty1 (./home/domicile.nix starts it at login there).
{ inputs, ... }:
{
  imports = [ inputs.domicile.nixosModules.default ];

  programs.domicile = {
    enable = true;
    # Casting to TVs opens TCP 7236 and runs Avahi.
    miracast = false;
  };

  # Its compositor and engine, prebuilt for each `release`.
  nix.settings = {
    extra-substituters = [ "https://packages.domicile-desktop.com/nix" ];
    extra-trusted-public-keys = [
      "packages.domicile-desktop.com-1:iAulr298MtC52WMi2GPI8bqPEvOXHoQtSRAGOo0ny90="
    ];
  };

  # The group's pam_limits let the frame threads raise their priority.
  users.users.lillecarl.extraGroups = [ "domicile" ];
}
