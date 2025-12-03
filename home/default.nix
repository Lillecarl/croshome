{
  config,
  pkgs,
  lib,
  ...
}:
{
  users.users.lillecarl = {
    isNormalUser = true;
  };
  # home-manager.users.lillecarl =
  #   { ... }:
  #   {
  #     imports = [ ./lillecarl.nix ];
  #     home.stateVersion = config.system.stateVersion;
  #   };
}
