{ ... }:
{
  config = {
    nixpkgs = {
      config.allowUnfree = true;
      overlays = [
        (import ./pkgs)
      ];
    };
  };
}
