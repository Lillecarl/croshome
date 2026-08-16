{ ... }:
{
  # fontconfig only. The font package is in ../fonts.nix, because macOS wants
  # it too and only this database is Linux-specific.
  fonts.fontconfig = {
    enable = true;
    defaultFonts = {
      monospace = [ "Hack" ];
      emoji = [ "Hack" ];
    };
  };
}
