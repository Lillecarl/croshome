{ config, lib, ... }:
{
  config = {
    programs.foot = {
      enable = true;
      settings = {
        main = {
          shell = lib.getExe config.programs.fish.package;
        };
        url = {
          launch = "xdg-open \${url}";
        };
        key-bindings =
          let
            # Bind everything with and without Mod2 (numlock) since it's locked on ChromeOS for some reason
            csMod =
              keys:
              lib.pipe keys [
                lib.toList
                (lib.map (key: "Control+Shift+${key} Control+Shift+Mod2+${key}"))
                (lib.concatStringsSep " ")
              ];
          in
          {
            clipboard-copy = csMod "c";
            clipboard-paste = csMod "v";
            font-decrease = csMod "minus";
            font-increase = csMod "equal";
            font-reset = csMod "0";
            spawn-terminal = csMod "n";
            show-urls-copy = csMod "p";
            show-urls-launch = csMod "o";
          };
      };
    };
  };
}
