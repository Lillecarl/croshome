# sops-nix over ../secrets/sops, for NixOS and nix-darwin. The host decrypts
# with its ssh host key; recipients live in ../secrets/sops/keys.nix.
#
# User secrets: a home-manager module sets `croshome.userSecrets` (see
# ./home/user-secrets.nix), and this module decrypts each one as root, owned
# by that user. One identity per host, and no passphrase-less user key.
{
  config,
  inputs,
  lib,
  pkgs,
  platform,
  ...
}:
let
  cfg = config.croshome.secrets;
  dir = ../secrets/sops;
  keys = import (dir + "/keys.nix");

  userSecrets = lib.concatMapAttrs (
    user: hm:
    lib.mapAttrs' (
      name: s:
      lib.nameValuePair "${user}/${name}" (
        {
          inherit (s) key format;
          sopsFile = s.file;
          owner = user;
        }
        // lib.optionalAttrs platform.isLinux { inherit (config.users.users.${user}) group; }
      )
    ) (hm.croshome.userSecrets or { })
  ) (config.home-manager.users or { });
in
{
  imports = [
    (inputs.sops-nix.outPath + (if platform.isDarwin then "/modules/nix-darwin" else "/modules/sops"))
  ];

  options.croshome.secrets = {
    enable = lib.mkEnableOption "sops secrets from secrets/sops";
    host = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "Selects secrets/sops/hosts/<host>.yaml as the default file.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = keys.hosts ? ${cfg.host};
        message = ''
          ${cfg.host} is not in secrets/sops/keys.nix, so it can decrypt nothing.
          On ${cfg.host}: ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub
          Add the result under hosts, then run `secrets sync`.
        '';
      }
    ];
    sops = {
      defaultSopsFile = dir + "/hosts/${cfg.host}.yaml";
      age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
      gnupg.sshKeyPaths = [ ];
      secrets = userSecrets;
    };
    environment.systemPackages = [
      pkgs.croshome-secrets
      pkgs.sops
    ];
  };
}
