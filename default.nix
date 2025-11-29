let
  inputs =
    (
      let
        lockFile = builtins.readFile ./flake.lock;
        lockAttrs = builtins.fromJSON lockFile;
        fcLockInfo = lockAttrs.nodes.flake-compatish.locked;
        flake-compatish = import fcLockInfo.path;
      in
      flake-compatish ./.
    ).inputs;

  pkgs = import inputs.nixpkgs { };
in
{
  inherit inputs pkgs;
  home = inputs.home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    modules = [
      ./home
    ];
    extraSpecialArgs = {
      inherit inputs;
    };
  };
}
