{ lib, config, ... }:
{
  config = lib.mkIf true {
    services.avizo = {
      enable = true;
    };
  };
}
