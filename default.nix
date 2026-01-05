let
  inputs =
    (
      let
        lockFile = builtins.readFile ./flake.lock;
        lockAttrs = builtins.fromJSON lockFile;
        fcLockInfo = lockAttrs.nodes.flake-compatish.locked;
        flake-compatish = import (builtins.fetchTree fcLockInfo);
      in
      flake-compatish ./.
    ).inputs;

  pkgs = import inputs.nixpkgs {
    config.allowUnfree = true;
  };
in
rec {
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
  hetztop = hetztopSystem { system = builtins.currentSystem; };
  hetztopx = hetztopSystem { system = "x86_64-linux"; };
  hetztopSystem =
    {
      system ? builtins.currentSystem,
    }:
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        ./nixos
      ];
      specialArgs = {
        inherit inputs;
        self = ./.;
        selfStr = toString ./.;
      };
    };
}
