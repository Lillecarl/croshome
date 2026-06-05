let
  inputs =
    (
      let
        lockFile = builtins.readFile ./flake.lock;
        lockAttrs = builtins.fromJSON lockFile;
        fcLockInfo = lockAttrs.nodes.flake-compatish.locked;
        flake-compatish = import (fetchTree fcLockInfo);
      in
      flake-compatish {
        source = ./.;
        overrides = {
          self = ./.;
          llm-agents = /home/lillecarl/Code/llm-agents.nix;
          oh-my-pi = /home/lillecarl/Code/oh-my-pi;
          hermes-agent =
            let
              latestRelease = builtins.fromJSON (
                builtins.readFile (
                  builtins.fetchurl {
                    url = "https://api.github.com/repos/NousResearch/hermes-agent/releases/latest";
                    name = "hermes-latest-release.json";
                  }
                )
              );
              tag = latestRelease.tag_name;
            in
            fetchTree {
              type = "github";
              owner = "NousResearch";
              repo = "hermes-agent";
              ref = tag;
            };
        };
      }
    ).inputs;
in
rec {
  inherit inputs;
  pkgs = import inputs.nixpkgs {
    system = builtins.currentSystem;
    overlays = [ (import ./pkgs) ];
  };
  home = inputs.home-manager.lib.homeManagerConfiguration {
    pkgs = import inputs.nixpkgs { };
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
  oc = hetztop.config;
  hc = oc.home-manager.users.lillecarl;
}
