# This machine's Nix store as a binary cache for the cluster on it.
# nixkube's node pods substitute from it (../../../kube/modules/nixkube.nix),
# so a pod can run a store path built here without a push to anywhere.
#
# nix-serve-ng listens on every address, and the firewall opens port 5000
# on no interface. cni0 is trusted (./default.nix), so only pods reach it.
#
# The signing key is made on this machine the first time and stays here.
# Its public half is a literal in the nixkube module:
#
#   cat /var/lib/nix-serve-key/key.pub
{ config, pkgs, ... }:
let
  keyDir = "/var/lib/nix-serve-key";
in
{
  services.nix-serve = {
    enable = true;
    package = pkgs.nix-serve-ng;
    # The default is IPv4 only, and pods here are IPv6 only. warp's name
    # for any IPv6 address: nix-serve-ng's --listen parser rejects an IPv6
    # literal, bracketed or not.
    bindAddress = "*6";
    secretKeyFile = "${keyDir}/key";
  };

  systemd.services.nix-serve-keygen = {
    description = "Make nix-serve's signing key and its public half";
    wantedBy = [ "nix-serve.service" ];
    before = [ "nix-serve.service" ];
    path = [ config.nix.package ];
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "nix-serve-key";
      # The directory is readable so the public key is. The secret key is
      # 0600 by the umask.
      StateDirectoryMode = "0755";
      UMask = "0077";
    };
    script = ''
      if [ ! -e ${keyDir}/key ]; then
        nix key generate-secret --key-name ${config.networking.hostName}-nix-serve-1 > ${keyDir}/key.tmp
        mv ${keyDir}/key.tmp ${keyDir}/key
      fi
      nix key convert-secret-to-public < ${keyDir}/key > ${keyDir}/key.pub
      chmod 0644 ${keyDir}/key.pub
    '';
  };
}
