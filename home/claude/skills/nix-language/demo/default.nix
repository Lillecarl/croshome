let
  compat = import ./nix/compat.nix;
in
{
  inputs ? compat.inputs,
  system ? builtins.currentSystem,
  # Empty config and overlays: without them nixpkgs reads
  # ~/.config/nixpkgs, and the build depends on whose machine runs it.
  pkgs ? import inputs.nixpkgs {
    inherit system;
    config = { };
    overlays = [ ];
  },
}:

let
  greet = pkgs.callPackage ./nix/package.nix { };
in
{
  inherit greet;
  default = greet;

  overlay = import ./nix/overlay.nix;
  nixosModule = ./nix/module.nix;

  shell = pkgs.callPackage ./nix/shell.nix { inherit greet; };
  # callPackages, not callPackage: the latter adds `override` to the set,
  # and `nix flake check` rejects a check that is not a derivation.
  checks = pkgs.callPackages ./nix/checks.nix { inherit greet; };
  formatter = pkgs.nixfmt-tree;
}
