{ lib, config, ... }:
{
  config = lib.mkIf true {
    services.swaync = {
      enable = true;

      settings = {
        layer = "overlay";
        positionX = "right";
        positiony = "center";
        hide-on-clear = true;
        layer-shell = true;
      };
    };
  };
}
