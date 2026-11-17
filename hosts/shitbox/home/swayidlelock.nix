{
  lib,
  config,
  pkgs,
  ...
}:
let
  lockScript = lib.getExe pkgs.swaylock;
in
{
  config = lib.mkIf true {
    catppuccin.swaylock.enable = false;

    programs.swaylock = {
      enable = true;

      settings = {
        daemonize = true;
        image = "${../lockscreen.jpg}";
        scaling = "center";
        color = "000000";
      };
    };

    services.swayidle = {
      enable = true;

      events = {
        before-sleep = lockScript;
        lock = lockScript;
      };

      timeouts = [
        {
          timeout = 300;
          command = lockScript;
        }
        {
          timeout = 1800;
          command = "${lib.getExe pkgs.niri} msg action power-off-monitors";
        }
      ];
    };
  };
}
