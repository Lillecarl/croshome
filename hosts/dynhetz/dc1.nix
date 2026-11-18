# A permanent tunnel into Dynamist's old datacenter, "dc1". The values are
# nub's; the Mac runs the same tunnel (../macbook/default.nix). dynhetz dials
# out and only originates traffic, so the firewall needs nothing.
{ config, ... }:
{
  # networkd reads PrivateKeyFile as the systemd-network user.
  sops.secrets.wg-dc1-key = {
    sopsFile = ../../secrets/sops/dc1.yaml;
    owner = "root";
    group = "systemd-network";
    mode = "0440";
  };

  systemd.network.netdevs."30-dc1" = {
    netdevConfig = {
      Kind = "wireguard";
      Name = "dc1";
    };
    wireguardConfig = {
      PrivateKeyFile = config.sops.secrets.wg-dc1-key.path;
      # networkd adds no routes for AllowedIPs unless told which table.
      RouteTable = "main";
    };
    wireguardPeers = [
      {
        PublicKey = "3dPS9vn68QIXobuU8HG7u/GlUlY0Hjs3LbH6jeq0wUc=";
        Endpoint = "155.4.106.42:51820";
        PersistentKeepalive = 30;
        # All twelve. A short list comes up clean and quietly misses a subnet.
        AllowedIPs = [
          "10.0.250.1/32"
          "10.0.4.0/24"
          "10.0.5.0/24"
          "10.0.10.0/24"
          "10.0.90.0/24"
          "10.0.100.0/24"
          "100.64.0.0/22"
          "10.240.0.0/16"
          "10.7.10.0/24"
          "10.7.0.0/24"
          "10.7.5.0/24"
          "10.0.95.0/24"
        ];
      }
    ];
  };

  systemd.network.networks."30-dc1" = {
    matchConfig.Name = "dc1";
    address = [ "10.0.250.129/24" ];
    # dynami.st resolves through dc1's resolver; everything else stays global.
    dns = [ "10.0.250.1" ];
    domains = [ "~dynami.st" ];
    # A datacenter that is down must not hold up network-online.target.
    linkConfig.RequiredForOnline = "no";
  };
}
