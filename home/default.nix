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
      hashedPassword = "$y$j9T$U4zBBS9RMV9YMttHauO8k0$V.KT/P/AdBTXXT8f6p9EIlCsZV5UnaPDgEVtUvUJU3C";
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
