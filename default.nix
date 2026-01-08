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
in
rec {
  inherit inputs;
  pkgs = import inputs.nixpkgs {
    config.allowUnfree = true;
    overlays = [ ];
  };
  home = inputs.home-manager.lib.homeManagerConfiguration {
    modules = [
      ./cros
      ./nixpkgs.nix
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
        ./nixpkgs.nix
      ];
      specialArgs = {
        inherit inputs;
        self = ./.;
        selfStr = toString ./.;
      };
    };
}
