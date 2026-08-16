{ pkgs, ... }:
{
  # The font itself is shared: home-manager links it into ~/Library/Fonts on
  # macOS and into the fontconfig path on Linux, and kitty and foot both want
  # the Nerd Font glyphs.
  #
  # What is *not* shared is fontconfig, the Linux font database that maps
  # "monospace" onto this file. macOS has its own and ignores it, so that part
  # lives in ./linux/fonts.nix.
  home.packages = [ pkgs.nerd-fonts.hack ];
}
