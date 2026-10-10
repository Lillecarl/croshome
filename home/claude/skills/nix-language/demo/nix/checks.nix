{
  lib,
  nixos,
  runCommand,
  emptyFile,
  nixfmt,
  greet,
}:

greet.passthru.tests
// {
  inherit greet;

  nixfmt =
    runCommand "nixfmt-check"
      {
        nativeBuildInputs = [ nixfmt ];
        src = lib.fileset.toSource {
          root = ../.;
          fileset = lib.fileset.fileFilter (file: file.hasExt "nix") ../.;
        };
      }
      ''
        find "$src" -name '*.nix' -exec nixfmt --check {} +
        touch $out
      '';

  # Evaluation only, no VM: proves the module wires the package in.
  module =
    let
      system = nixos {
        imports = [ ./module.nix ];
        programs.greet.enable = true;
        boot.isContainer = true;
        system.stateVersion = lib.trivial.release;
      };
    in
    assert lib.elem greet system.config.environment.systemPackages;
    emptyFile;
}
