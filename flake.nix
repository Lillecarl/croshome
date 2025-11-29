{
  inputs = {
    # flake-compatish.url = "github:lillecarl/flake-compatish/main";
    flake-compatish = {
      url = "path:/home/lillecarl/Code/flake-compatish";
      flake = false;
    };
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      # url = "github:nix-community/home-manager/master";
      url = "path:/home/lillecarl/Code/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    catppuccin = {
      url = "github:catppuccin/nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = inputs: {};
}
