# A point-to-point tunnel to hetztop. ../hetztop/wireguard.nix is the other
# end. shitbox is behind NAT, so it dials out and keeps the mapping open.
{ ... }:
{
  networking.wireguard.interfaces.wg-hetztop = {
    ips = [ "10.44.33.2/24" ];
    # Made by hand in 2025 for the tunnel in ~/Code/nixos. Kept so hetztop's
    # peer entry stays the same key.
    privateKeyFile = "/etc/wireguard/private.key";
    peers = [
      {
        name = "hetztop";
        # /var/lib/wireguard/wg-shitbox.key.pub on hetztop.
        publicKey = "yZ2I1lvKxlVzLRdAQ98bN/9G/fcIak6eipzwCPcGEjI=";
        endpoint = "65.108.150.98:51820";
        allowedIPs = [ "10.44.33.1/32" ];
        persistentKeepalive = 25;
      }
    ];
  };
}
