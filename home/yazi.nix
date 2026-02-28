{ config, selfStr, ... }:
{
  config = {
    programs.yazi = {
      enable = true;
      enableFishIntegration = false;
      shellWrapperName = "y";
    };
  };
}
