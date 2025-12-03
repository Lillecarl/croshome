let
  flake = (
    let
      lockFile = builtins.readFile ./flake.lock;
      lockAttrs = builtins.fromJSON lockFile;
      fcLockInfo = lockAttrs.nodes.flake-compatish.locked;
      flake-compatish = import (builtins.fetchTree fcLockInfo);
    in
    flake-compatish ./.
  );
  inherit (flake) inputs;

  pkgs = import inputs.nixpkgs { };
in
{
  inherit inputs pkgs;
  home = inputs.home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    modules = [
      ./cros
    ];
    extraSpecialArgs = {
      inherit inputs;
    };
  };
}
// flake.impure
