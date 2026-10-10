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
  inherit (pkgs) lib;

  greet = pkgs.callPackage ./nix/package.nix { };
in
{
  inherit greet;
  default = greet;

  overlay = import ./nix/overlay.nix;
  nixosModule = ./nix/module.nix;

  shell = pkgs.mkShell {
    inputsFrom = [ greet ];
    packages = [ pkgs.nixfmt ];
  };

  checks = greet.passthru.tests // {
    inherit greet;

    # Evaluation only, no VM: proves the module wires the package in.
    module =
      let
        system = pkgs.nixos {
          imports = [ ./nix/module.nix ];
          programs.greet.enable = true;
          boot.isContainer = true;
          system.stateVersion = lib.trivial.release;
        };
      in
      assert lib.elem greet system.config.environment.systemPackages;
      pkgs.emptyFile;
    nixfmt =
      pkgs.runCommand "nixfmt-check"
        {
          nativeBuildInputs = [ pkgs.nixfmt ];
          src = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.fileFilter (file: file.hasExt "nix") ./.;
          };
        }
        ''
          find "$src" -name '*.nix' -exec nixfmt --check {} +
          touch $out
        '';
  };

  formatter = pkgs.nixfmt-tree;
}
