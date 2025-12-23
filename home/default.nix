{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:
{
  config = {
    programs.fish.enable = true;
    users.users.lillecarl = {
      extraGroups = [ "wheel" ];
      isNormalUser = true;
      openssh.authorizedKeys.keyFiles = [ ../lillecarl.pub ];
      shell = pkgs.fish;
    };
    home-manager = {
      useGlobalPkgs = true;
      extraSpecialArgs = { inherit inputs; };
      users.lillecarl = import ./lillecarl.nix;
    };
  };
}
