{ pkgs, ... }:
{
  config = {
    virtualisation.podman = {
      enable = true;
      autoPrune.enable = true;
      dockerCompat = true;
      dockerSocket.enable = true;
    };
    environment.systemPackages = [
      pkgs.kind
    ];
  };
}
