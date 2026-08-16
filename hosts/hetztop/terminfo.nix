{ pkgs, ... }:
{
  config = {
    environment.systemPackages = [ pkgs.kitty.terminfo ];
  };
}
