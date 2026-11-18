# sops-nix over ../../secrets/sops. The host decrypts with its ssh host key;
# recipients live in ../../secrets/sops/keys.nix.
#
# User secrets: a home-manager module sets `croshome.userSecrets` (see
# ../home/user-secrets.nix), and this module decrypts each one here, as root,
# owned by that user. One identity per host, and no passphrase-less user key.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.croshome.secrets;
  dir = ../../secrets/sops;

  userSecrets = lib.concatMapAttrs (
    user: hm:
    lib.mapAttrs' (
      name: s:
      lib.nameValuePair "${user}/${name}" {
        inherit (s) key format;
        sopsFile = s.file;
        owner = user;
        inherit (config.users.users.${user}) group;
      }
    ) (hm.croshome.userSecrets or { })
  ) config.home-manager.users;
in
{
  imports = [ (inputs.sops-nix.outPath + "/modules/sops") ];

  options.croshome.secrets = {
    enable = lib.mkEnableOption "sops secrets from secrets/sops";
    host = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "Selects secrets/sops/hosts/<host>.yaml as the default file.";
    };
  };

  config = lib.mkIf cfg.enable {
    sops = {
      defaultSopsFile = dir + "/hosts/${cfg.host}.yaml";
      age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
      gnupg.sshKeyPaths = [ ];
      secrets = userSecrets;
    };
    environment.systemPackages = [ pkgs.croshome-secrets ];
  };
}
