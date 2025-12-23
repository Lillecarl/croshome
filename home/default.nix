{
  config,
  pkgs,
  lib,
  ...
}:
{
  users.users.lillecarl = {
    isNormalUser = true;
      openssh.authorizedKeys.keyFiles = [ ../lillecarl.pub ];
  };
  # home-manager.users.lillecarl =
  #   { ... }:
  #   {
  #     imports = [ ./lillecarl.nix ];
  #     home.stateVersion = config.system.stateVersion;
  #   };
}
