{
  lib,
  pkgs,
  ...
}:
let
  backgroundImage = pkgs.fetchurl {
    url = "https://github.com/NixOS/nixos-artwork/blob/master/wallpapers/nix-wallpaper-watersplash.png?raw=true";
    sha256 = "sha256-6Gdjzq3hTvUH7GeZmZnf+aOQruFxReUNEryAvJSgycQ=";
  };
in
{
  config = lib.mkIf true {
    # niri's alone: domicile offers no layer-shell, and its shell page draws
    # the background itself.
    systemd.user.services.swaybg = {
      Unit = {
        Description = "Sway background image daemon";
        PartOf = [ "niri.service" ];
        After = [ "niri.service" ];
      };

      Service = {
        ExecStart = "${lib.getExe pkgs.swaybg} --image ${backgroundImage} --mode center";
      };
      Install = {
        WantedBy = [ "niri.service" ];
      };
    };
  };
}
