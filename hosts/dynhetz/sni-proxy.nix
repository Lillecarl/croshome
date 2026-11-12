# The public IPv4's :443, for nixlab3. HAProxy reads the SNI of each TLS
# hello without decrypting and passes the stream to nixlab3's Traefik, which
# is IPv6-only: this is the 4-to-6 step that jool's static BIB did. sg1 has
# public IPv4s of its own on sg1-router (solid-kubernetes
# environments/sg1/edge.nix).
#
# The upstream dial carries a PROXY v2 header with the IPv4 client, and
# leaves from eth0's IPv6, the address nixlab3's Traefik trusts for it
# (solid-kubernetes environments/nixlab3/kubernetes).
{ config, ... }:
let
  ipv4 = "37.27.129.237";
  # Bracketed: HAProxy reads a bare IPv6 as host:port at its last colon,
  # and refuses it (checked with `haproxy -c`, 3.4.4).
  source = "[2a01:4f9:3071:11d7::2]";
in
{
  services.haproxy = {
    enable = true;
    config = ''
      global
        log stdout format raw local0 notice

      defaults
        mode tcp
        log global
        option tcplog
        timeout connect 5s
        # Long-lived websockets and gRPC streams pass through here.
        timeout client 1h
        timeout server 1h

      frontend tls
        bind ${ipv4}:443
        tcp-request inspect-delay 5s
        tcp-request content accept if { req_ssl_hello_type 1 }
        default_backend nixlab3

      backend nixlab3
        server traefik [2a01:4f9:3071:11d7:e2::1]:443 send-proxy-v2 source ${source}
    '';
  };

  # Upstream deficiency: nixpkgs' haproxy module reads /etc/haproxy.cfg
  # and declares no trigger on it, so a config change leaves the unit
  # file unchanged and the switch never reloads HAProxy. Measured
  # 2026-10-29: a new backend sat in /etc for an hour, unused.
  systemd.services.haproxy.reloadTriggers = [ config.environment.etc."haproxy.cfg".source ];

  networking.firewall.extraCommands = ''
    iptables -A nixos-fw -d ${ipv4} -p tcp --dport 443 -j nixos-fw-accept
  '';
}
