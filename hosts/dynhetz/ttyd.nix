{ config, lib, pkgs, ... }:

{
  services.ttyd = {
    enable = false;
    writeable = true;
  };

  networking.firewall.allowedTCPPorts = [ config.services.ttyd.port ];
}
