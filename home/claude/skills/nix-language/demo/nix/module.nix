{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.greet;
in
{
  options.programs.greet = {
    enable = lib.mkEnableOption "greet";

    # Built from the consumer's pkgs, never a pinned one, so the module adds
    # no second nixpkgs. Takes pkgs.greet when the overlay is applied.
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.greet or (pkgs.callPackage ./package.nix { });
      defaultText = lib.literalExpression "pkgs.greet";
      description = "The greet package to install.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
  };
}
