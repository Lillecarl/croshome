# This machine's Nix store as a binary cache for the cluster on it.
# nixkube's node pods substitute from it (../../../kube/modules/nixkube.nix),
# so a pod can run a store path built here without a push to anywhere.
#
# harmonia listens on every address, and the firewall opens port 5000 on
# no interface. cni0 is trusted (./default.nix), so only pods reach it.
#
# The signing key is made on this machine the first time and stays here.
# Its public half is a literal in the nixkube module:
#
#   cat /var/lib/harmonia-key/key.pub
{ config, ... }:
let
  keyDir = "/var/lib/harmonia-key";
in
{
  services.harmonia.cache = {
    enable = true;
    signKeyPaths = [ "${keyDir}/key" ];
  };

  systemd.services.harmonia-keygen = {
    description = "Make harmonia's signing key and its public half";
    # multi-user.target too, so a switch runs a changed script while
    # harmonia is already up.
    wantedBy = [
      "harmonia.service"
      "multi-user.target"
    ];
    before = [ "harmonia.service" ];
    path = [ config.nix.package ];
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "harmonia-key";
      # The directory is readable so the public key is. The secret key is
      # 0600 by the umask.
      StateDirectoryMode = "0755";
      UMask = "0077";
    };
    script = ''
      if [ ! -e ${keyDir}/key ]; then
        nix key generate-secret --key-name ${config.networking.hostName}-harmonia-1 > ${keyDir}/key.tmp
        mv ${keyDir}/key.tmp ${keyDir}/key
      fi
      nix key convert-secret-to-public < ${keyDir}/key > ${keyDir}/key.pub
      chmod 0644 ${keyDir}/key.pub
    '';
  };
}
