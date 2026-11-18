# Secrets a home-manager module needs as a file. The system decrypts them
# (../secrets.nix), so this module only declares and computes the path. With
# no system underneath (cros), nothing decrypts them.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  user = config.home.username;
in
{
  options.croshome.userSecrets = lib.mkOption {
    default = { };
    description = "Secrets decrypted to /run/secrets/<user>/<name>, owned by the user.";
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          options = {
            file = lib.mkOption {
              type = lib.types.path;
              default = ../../secrets/sops/user.yaml;
            };
            key = lib.mkOption {
              type = lib.types.str;
              default = name;
              description = "Path in the file, `/`-separated.";
            };
            format = lib.mkOption {
              type = lib.types.enum [
                "yaml"
                "json"
                "binary"
                "dotenv"
                "ini"
              ];
              default = "yaml";
            };
            path = lib.mkOption {
              type = lib.types.str;
              readOnly = true;
              default = "/run/secrets/${user}/${name}";
            };
          };
        }
      )
    );
  };

  config = lib.mkIf (config.croshome.userSecrets != { }) {
    home.packages = [
      pkgs.croshome-secrets
      pkgs.sops
    ];
    home.sessionVariables.SOPS_AGE_KEY_CMD = "secrets key";
  };
}
