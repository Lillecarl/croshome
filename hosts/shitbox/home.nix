{ osConfig, ... }:
{
  imports = [
    ../../home
    ./home
  ];

  # The NixOS underneath is 20.09-era, and the standalone home-manager this
  # replaces said 20.09 too; take it from there rather than keep a copy.
  home.stateVersion = osConfig.system.stateVersion;

  programs.agentMachine = {
    hostName = "shitbox";
    cloneDir = "~/Code";
  };
}
