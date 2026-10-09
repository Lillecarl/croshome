# This machine's Nix store as a binary cache for the clusters on it.
# nixkube's node pods substitute from it, on the host cluster
# (../../../kube/modules/nixkube.nix) and in the guest cluster nixlab3
# (solid-kubernetes), so a pod can run a store path built here without a
# push to anywhere.
#
# Served by Harmonia, not nix-serve-ng: nixpkgs builds nix-serve-ng against
# Lix, and its CppNix path calls libstore APIs Nix 2.35 removed
# (initLibStore, openStore(), getDefaultSubstituters) -- the flag-off build
# fails, and upstream HEAD is identical. Harmonia shells out to the `nix`
# CLI instead of linking libstore, so no implementation coupling exists to
# maintain.
#
# Harmonia listens on every address. cni0 is trusted (./default.nix),
# and the firewall opens port 5000 on the VM bridge for the guest nodes.
#
# The signing key is made on this machine the first time and stays here.
# Its public half is a literal in the nixkube module:
#
#   cat /var/lib/nix-serve-key/key.pub
{ config, pkgs, ... }:
let
  keyDir = "/var/lib/nix-serve-key";
  network = import ./network.nix;
in
{
  networking.firewall.interfaces.${network.vmBridge}.allowedTCPPorts = [ 5000 ];

  services.harmonia.cache = {
    enable = true;
    # The key the nix-serve era generated. Guests pin its public half in
    # ../../../kube/modules/nixkube.nix, so the file stays where it is
    # under its name; only the server reading it changes.
    signKeyPaths = [ "${keyDir}/key" ];
    settings = {
      # The default already, stated because it matters: pods here are IPv6
      # only, and nix-serve-ng's warp listener could not express an IPv6
      # wildcard (`*6`). Same port, so the firewall rule above and the
      # guests' substituter URL stand.
      bind = "[::]:5000";
    };
  };

  systemd.services.harmonia-keygen = {
    description = "Make Harmonia's signing key and its public half";
    wantedBy = [ "harmonia.service" ];
    before = [ "harmonia.service" ];
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
