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
    # Only ./hosts/macbook/linux-builder.nix reads this, and it deliberately
    # does not follow nixpkgs. Hydra builds darwin.linux-builder for the
    # release channels and not for unstable, so taking the VM from unstable
    # leaves 21 aarch64-linux derivations that nothing has built and that a Mac
    # cannot build -- which is the exact bootstrap the builder exists to break.
    nixpkgs-stable.url = "https://channels.nixos.org/nixos-25.11/nixexprs.tar.xz";
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
    # The `develop` branch. The packaging used to live only on a `nix` branch,
    # which is what this tracked; that branch has since been merged into
    # develop, so following it now gets the packaging and the actual
    # development of the tool together rather than a packaging branch frozen
    # against an older tree.
    #
    # A source tree, and not a flake, for the same reason as nanopynix below.
    # Its `default.nix` takes `pkgs`, so this configuration's package set
    # builds it and no second nixpkgs is instantiated. Its own flake exists to
    # wrap that same file for people who want a flake.
    #
    # `github:` and not the `git@` SSH remote it is cloned from. The repository
    # is public, so this needs no key -- which matters for hetztop, and for any
    # clone of this configuration that is not on a machine holding one.
    phabfive = {
      url = "github:Lillecarl/phabfive/develop";
      flake = false;
    };
    # A source tree, and not a flake, for the same reason as nanopynix below --
    # and here the reason is sharper. agenix pins its own `nixpkgs` to
    # nixos-25.05 and does not follow ours, so evaluating its outputs would
    # instantiate a second package set on a different release.
    #
    # Nothing is lost by it. Its flake states `nixosModules.age` and
    # `darwinModules.age` as the same plain path, ./modules/age.nix, and builds
    # its CLI with a bare `callPackage ./pkgs/agenix.nix`. ../secrets/default.nix
    # reaches both directly.
    agenix = {
      url = "github:ryantm/agenix";
      flake = false;
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
