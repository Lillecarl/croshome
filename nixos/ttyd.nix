{ config, lib, pkgs, ... }:

{
  services.ttyd = {
    enable = true;
    writeable = true;
  };

  networking.firewall.allowedTCPPorts = [ config.services.ttyd.port ];
}
