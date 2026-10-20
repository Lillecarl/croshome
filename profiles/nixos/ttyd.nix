{ config, lib, pkgs, ... }:

{
  services.ttyd = {
    enable = false;
    writeable = true;
  };

  networking.firewall.allowedTCPPorts = lib.mkIf config.services.ttyd.enable [
    config.services.ttyd.port
  ];
}
