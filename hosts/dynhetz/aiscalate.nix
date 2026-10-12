# aiscalate: timeboxed shell-command tokens for AI agents.
#
# TEMPORARY wiring: imported impurely from the checkout beside this repo
# until github:Lillecarl/aiscalate exists and can become a flake input
# (with an overrides.nix entry and the pkgs.aiscalate overlay). Then this
# file shrinks to the module import by input path plus enable, and the
# package falls back to its pkgs.aiscalate default.
{ pkgs, ... }:
{
  imports = [ /home/lillecarl/Code/aiscalate/nix/nixos-module.nix ];

  services.aiscalate = {
    enable = true;
    package = (import /home/lillecarl/Code/aiscalate { inherit pkgs; }).aiscalate;
  };
}
