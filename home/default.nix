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
