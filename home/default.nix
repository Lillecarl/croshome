{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:
{
  config = {
    users.users.lillecarl = {
      isNormalUser = true;
      openssh.authorizedKeys.keyFiles = [ ../lillecarl.pub ];
    };
    home-manager = {
      useGlobalPkgs = true;
      extraSpecialArgs = { inherit inputs; };
      users.lillecarl = import ./lillecarl.nix;
    };
  };
}
