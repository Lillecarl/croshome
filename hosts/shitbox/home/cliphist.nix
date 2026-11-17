{ lib, config, ... }:
{
  config = lib.mkIf true {
    services.cliphist = {
      enable = true;
      extraOptions = [
        "-max-items"
        "500"
      ];
    };
  };
}
