{
  inputs = {
    flake-compatish.url = "github:lillecarl/flake-compatish";
    # nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    catppuccin = {
      url = "github:catppuccin/nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-darwin = {
      url = "github:nix-darwin/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    llm-agents = {
      url = "github:numtide/llm-agents.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    crane.url = "github:ipetkov/crane";
    bun2nix = {
      url = "github:nix-community/bun2nix/staging-2.1.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    acpcli = {
      url = "github:lillecarl/acpcli";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # A source tree, and not a flake. `default.nix` of nanopynix takes `pkgs`,
    # so this package set builds it and no second nixpkgs is instantiated.
    # `flake = false` is what keeps the outputs of nanopynix unevaluated:
    # flake-compatish gives a node with `flake = false` its source only.
    nanopynix = {
      url = "github:Lillecarl/nanopynix";
      flake = false;
    };
  };
  outputs =
    inputs:
    let
      default = import ./default.nix;
    in
    {
      nixosConfigurations.hetztop = default.hetztopSystem { system = "x86_64-linux"; };
      darwinConfigurations.macbook = default.macbookSystem { system = "aarch64-darwin"; };
    };
}
