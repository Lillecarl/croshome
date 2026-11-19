# shitbox: the desktop. Ryzen, Intel Arc for niri, an NVIDIA card for the
# Windows VM. Moved here from ~/Code/nixos.
#
# Two things must not break: the disk (./hardware.nix) and the niri session
# (./desktop.nix, ./home). ./check-contract diffs both against a reference
# before anything is activated.
{ lib, ... }:
{
  imports = [
    ../../profiles/nixos/base.nix
    ./hardware.nix
    ./desktop.nix
    ./vfio.nix
    ./wireguard.nix
    ./initrd-remote.nix
    ./secureboot.nix
  ];

  config = {
    networking = {
      hostName = "shitbox";
      hostId = "43211234";
      networkmanager.enable = true;
      firewall.enable = true;
    };

    users.users.lillecarl = {
      uid = 1000;
      extraGroups = [
        "wheel"
        "networkmanager"
        "video"
        "input"
        "uinput"
        "i2c"
      ];
    };
    home-manager.users.lillecarl = import ./home.nix;

    # A desktop, not a model server.
    services.ollama.enable = lib.mkForce false;

    programs.ai-rebuild = {
      enable = true;
      sudo.users = [ "lillecarl" ];
    };

    # Installed as 20.09; stateful defaults (home-manager included) follow it.
    system.stateVersion = "20.09";
  };
}
