{
  lib,
  pkgs,
  platform,
  ...
}:
{
  # The font is the same on all three machines. The way it is installed is not.
  #
  # Linux takes it here, through home.packages, because fontconfig reads the
  # home-manager profile. macOS takes it through `fonts.packages` in
  # ../hosts/macbook/default.nix, which puts it in /Library/Fonts/Nix Fonts.
  #
  # One path or the other, never both. home-manager also rsyncs every font in
  # home.packages into ~/Library/Fonts/HomeManager on darwin, so keeping it
  # here as well would register the same three families twice.
  #
  # The system path is the better one on macOS: it installs for every user and
  # every application, and it is in place before home-manager activates.
  #
  # What is *not* shared is fontconfig, the Linux font database that maps
  # "monospace" onto this file. macOS has its own and ignores it, so that part
  # lives in ./linux/fonts.nix.
  home.packages = lib.optional platform.isLinux pkgs.nerd-fonts.hack;
}
