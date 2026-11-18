# Remote unlock from anywhere: the initrd joins the WiFi and dials hetztop,
# so `ssh -p 2222 root@10.44.33.3` from hetztop reaches the passphrase agent.
# The cable port (igc, ./hardware.nix) has no cable.
#
# The sources are outside the repository and the store, and the bootloader
# install copies them, so a switch fails until both exist. lillecarl owns
# them, which grants nothing: lillecarl has ai-rebuild, so it is root here.
#
#   ~/.local/share/initrd-secrets/wpa_supplicant.conf   the network block
#   ~/.local/share/initrd-secrets/wg-initrd.key         wg genkey
{ ... }:
let
  secrets = "/home/lillecarl/.local/share/initrd-secrets";
  wifi = "wlp7s0";
in
{
  boot.initrd.wifi = {
    enable = true;
    interface = wifi;
    kernelModules = [ "mt7921e" ];
    configFile = "${secrets}/wpa_supplicant.conf";
  };
  boot.initrd.systemd.network.networks."10-wifi" = {
    matchConfig.Name = wifi;
    networkConfig.DHCP = "ipv4";
    dhcpV4Config.Hostname = "shitbox-boot";
  };

  # Its own key and address, not wg-hetztop's: this key is plaintext on /boot.
  boot.initrd.wireguard = {
    enable = true;
    privateKeyFile = "${secrets}/wg-initrd.key";
    address = [ "10.44.33.3/24" ];
    peers = [
      {
        # hetztop, as in ./wireguard.nix.
        PublicKey = "yZ2I1lvKxlVzLRdAQ98bN/9G/fcIak6eipzwCPcGEjI=";
        Endpoint = "65.108.150.98:51820";
        AllowedIPs = [ "10.44.33.1/32" ];
        PersistentKeepalive = 25;
      }
    ];
  };
}
