{ ... }:
{
  config = {
    fonts.fontconfig = {
      enable = true;
      defaultFonts = {
        monospace = [ "Hack" ];
        emoji = [ "Hack" ];
      };
    };
  };
}
