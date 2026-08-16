{ osConfig, ... }:
{
  imports = [ ../../home ];

  # There is a NixOS underneath this one, so take its stateVersion rather than
  # keep a second copy that can drift from it.
  home.stateVersion = osConfig.system.stateVersion;
}
