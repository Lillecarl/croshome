{ pkgs, ... }:
{
  # fontconfig only. The Hack package is in ../fonts.nix, because macOS wants
  # it too and only this database is Linux-specific.

  # Emoji are a separate font. Hack carries Nerd Font glyphs, which are icons
  # in the private use area, and no colour emoji at all.
  home.packages = [ pkgs.noto-fonts-color-emoji ];

  fonts.fontconfig = {
    enable = true;
    defaultFonts = {
      # The full family name, not "Hack". The Nerd Font package declares three
      # families -- Hack Nerd Font, Hack Nerd Font Mono and Hack Nerd Font
      # Propo -- and none of them is called "Hack". fontconfig compares family
      # names exactly, so the old value matched nothing and the alias did
      # nothing: `fc-match monospace` returned DejaVu Sans Mono.
      #
      # The Mono variant forces every icon into one cell. That is what a
      # terminal that assumes a fixed advance width wants; the plain family
      # draws the icons double width.
      monospace = [ "Hack Nerd Font Mono" ];
      emoji = [ "Noto Color Emoji" ];
    };
  };
}
