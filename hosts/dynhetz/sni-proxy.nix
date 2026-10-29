# The public IPv4's :443, shared by two clusters. HAProxy reads the SNI of
# each TLS hello without decrypting and passes the stream on: *.sg1 to sg1's
# Traefik, everything else to nixlab3's. Both clusters are IPv6-only, so
# this is also the 4-to-6 step that jool's static BIB did for one target.
#
# The upstream dial carries a PROXY v2 header with the IPv4 client, and
# leaves from eth0's IPv6, the one address both Traefiks trust for it
# (solid-kubernetes environments/{nixlab3,sg1}/kubernetes).
{ ... }:
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
        # Before sg1: Pangolin's resources sit under it, on their own edge.
        use_backend sg1-pangolin if { req_ssl_sni -m end .p.sg1.ch.se.eu.org }
        use_backend sg1 if { req_ssl_sni -m end .sg1.ch.se.eu.org } || { req_ssl_sni -m str sg1.ch.se.eu.org }
        default_backend nixlab3

      backend nixlab3
        server traefik [2a01:4f9:3071:11d7:e2::1]:443 send-proxy-v2 source ${source}

      backend sg1
        server traefik [2a01:4f9:3071:11d7:a2::1]:443 send-proxy-v2 source ${source}

      # The Traefik in Pangolin's Gerbil pod (solid-kubernetes
      # environments/sg1/kubernetes/pangolin.nix).
      backend sg1-pangolin
        server traefik [2a01:4f9:3071:11d7:a2::30]:443 send-proxy-v2 source ${source}
    '';
  };

  networking.firewall.extraCommands = ''
    iptables -A nixos-fw -d ${ipv4} -p tcp --dport 443 -j nixos-fw-accept
  '';
}
