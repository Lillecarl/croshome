{ config, osConfig, ... }:
{
  imports = [
    ../../home
    ./home
  ];

  # The NixOS underneath is 20.09-era, and the standalone home-manager this
  # replaces said 20.09 too; take it from there rather than keep a copy.
  home.stateVersion = osConfig.system.stateVersion;

  # The default ~/.ssh/id_ed25519 has a passphrase here; see shitbox-user in
  # ../../secrets/secrets.nix.
  age.identityPaths = [ "${config.home.homeDirectory}/.ssh/agenix" ];

  programs.agentMachine = {
    hostName = "shitbox";
    cloneDir = "~/Code";
  };
}
