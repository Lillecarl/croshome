{ pkgs, ... }:
{
  # fontconfig only. The Hack package is in ../fonts.nix, because macOS wants
  # it too and only this database is Linux-specific.

  # Emoji are a separate font. Hack carries Nerd Font glyphs, which are icons
  # in the private use area, and no colour emoji at all.
  #
  # Hack also lacks symbols TUIs draw, such as Claude Code's ⏺ ✻ ⎿ ⏵. These
  # two Noto fonts cover them, and they follow Hack in the monospace list,
  # so a fallback by fontconfig (pymux's `capture-client --png`) finds them.
  # Only these two variants, not the whole 50 MB family.
  home.packages = [
    pkgs.noto-fonts-color-emoji
    (pkgs.noto-fonts.override {
      variants = [
        "Noto Sans Symbols"
        "Noto Sans Symbols 2"
      ];
    })
  ];

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
      monospace = [
        "Hack Nerd Font Mono"
        "Noto Sans Symbols 2"
        "Noto Sans Symbols"
      ];
      emoji = [ "Noto Color Emoji" ];
    };
  };
}
