# A point-to-point tunnel to shitbox, which sits behind NAT at home and dials
# in. ../shitbox/wireguard.nix is the other end.
#
# The private key never leaves this host: the module generates it on first
# start, and only the public key is in the repository.
{ ... }:
let
  port = 51820;
in
{
  networking.wireguard.interfaces.wg-shitbox = {
    ips = [ "10.44.33.1/24" ];
    listenPort = port;
    privateKeyFile = "/var/lib/wireguard/wg-shitbox.key";
    generatePrivateKeyFile = true;
    peers = [
      {
        name = "shitbox";
        # /etc/wireguard/public.key on shitbox, the key its old tunnel used.
        publicKey = "nPky+d8cQ0dT5IfS3NPJX4v3Vmy/YegsLscY2vSWa3U=";
        allowedIPs = [ "10.44.33.2/32" ];
      }
    ];
  };

  networking.firewall.allowedUDPPorts = [ port ];
}
