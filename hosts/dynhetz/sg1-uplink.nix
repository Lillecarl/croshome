# Uplink for the SG1 lab cluster (Dynamist, sg1-nix): one WireGuard tunnel
# per node, BGP over each. Self-contained so it can be deleted whole: it only
# adds to options other files own (FRR config, NAT, firewall).
#
# dynhetz masquerades SG1's IPv4 egress and will DNAT public IPv4 into it, so
# the return path must come back through here. Each node dials its own
# interface over the internet, and its default route points into the tunnel.
# sg1-nix environments/sg1/nixos/docs/networking.md has the design, and
# modules/uplink.nix beside it the node side.
#
# Per node n, k = 2(n-1): wg-sg1-n<n> listens on 51820+n, dynhetz holds
# 10.247.102.k/31 and :a3:3::k/127, the node k+1. 10.247.102.254 and
# :a3:3::fe sit on every tunnel: Cilium's BGP peer config is cluster-wide, so
# it needs one dynhetz address every node can reach.
#
# Two sessions per node and family. Node FRR peers from its tunnel address
# and takes the default; Cilium peers from the node loopback (multihop) and
# announces pods and LoadBalancer IPs. Cilium cannot install received routes
# (./kubernetes/guest-routing.nix), hence node FRR.
{ lib, pkgs, ... }:
let
  v6 = "2a01:4f9:3071:11d7:a3";
  nodes = {
    "1" = "t6rrhXxLJV0XX/RX1sPKxIomKTN5M6RCIX7hccg2Wig=";
    "2" = "yZUrMTeZio2zVkyeyp7yrsw8vRJPgasncknhHXg4F1c=";
    "3" = "xPzI+dJ75sEeEF3IPeALv8RPPSM4Hk+IVyVN4JqLrik=";
    # The GX10s (solid-kubernetes environments/sg1/nixos): gx10-1759, gx10-1a5f.
    "4" = "L2jgy/vDwifd++ciAsR/k0hIapxCKsq8AGZ7M9tBkkc=";
    "5" = "Lqt9qN9MPXZbueD+ky+uxW5W0o5l8gxCrgI6JmRR91c=";
  };
  names = {
    "1" = "sg1-n1";
    "2" = "sg1-n2";
    "3" = "sg1-n3";
    "4" = "gx10-1759";
    "5" = "gx10-1a5f";
  };
  # The host keys pynixd pins, by host name ("<type> <key> root@<name>").
  hostKeys = lib.listToAttrs (
    map (
      line:
      let
        f = lib.splitString " " line;
      in
      lib.nameValuePair (lib.removePrefix "root@" (lib.elemAt f 2)) "${lib.elemAt f 0} ${lib.elemAt f 1}"
    ) (lib.filter (l: l != "") (lib.splitString "\n" (builtins.readFile ./sg1-builders.pub)))
  );
  tunnel =
    n: pub:
    let
      k = 2 * (lib.toInt n - 1);
      dev = "wg-sg1-n${n}";
    in
    ''
      ip link show ${dev} >/dev/null 2>&1 || ip link add ${dev} type wireguard
      wg set ${dev} private-key private.key listen-port ${toString (51820 + lib.toInt n)} \
        peer ${pub} allowed-ips 0.0.0.0/0,::/0
      ip link set ${dev} mtu 1420
      ip addr replace 10.247.102.${toString k}/31 dev ${dev}
      ip -6 addr replace ${v6}:3::${lib.toHexString k}/127 dev ${dev}
      ip addr replace 10.247.102.254/32 dev ${dev}
      ip -6 addr replace ${v6}:3::fe/128 dev ${dev} nodad
      # FRR's IPv6 sessions need a link-local address; WireGuard has none.
      ip -6 addr replace fe80::1/64 dev ${dev}
      ip link set ${dev} up
    '';
in
{
  systemd.services.wireguard-sg1 = {
    description = "WireGuard tunnels to the SG1 lab nodes";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [
      pkgs.wireguard-tools
      pkgs.iproute2
    ];
    # public.key is world-readable: sg1-nix pins it in the node config.
    script = ''
      set -euo pipefail
      install -d -m 0755 /var/lib/wireguard-sg1
      cd /var/lib/wireguard-sg1
      if [ ! -f private.key ]; then
        (umask 077; wg genkey > private.key)
      fi
      wg pubkey < private.key > public.key
      chmod 644 public.key
      ${lib.concatStrings (lib.mapAttrsToList tunnel nodes)}
    '';
  };

  networking.firewall.allowedUDPPortRanges = [
    {
      from = 51821;
      to = 51820 + lib.length (lib.attrNames nodes);
    }
  ];

  # SG1's downlink is the bottleneck: about 480 Mbit/s through the tunnels
  # (2 s curl from gx10-1759, 2026-10-24). A bulk download filled the ISP's
  # queue, BFD lost three probes and every node's session reset at once.
  # Shaping the outer WireGuard packets below that rate keeps the queue here,
  # under fq_codel. All tunnels share one class: they share one line.
  systemd.services.sg1-shaper = {
    description = "Shape WireGuard traffic to SG1 below its downlink";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.iproute2 ];
    script = ''
      tc qdisc replace dev eth0 root handle 1: htb default 10
      # Everything else: above eth0's 1 Gbit, so htb never holds it back.
      # htb's computed burst (1600 bytes) undershoots at these rates.
      tc class replace dev eth0 parent 1: classid 1:10 htb rate 10gbit burst 64k cburst 64k
      tc class replace dev eth0 parent 1: classid 1:20 htb rate 450mbit ceil 450mbit burst 32k cburst 32k
      tc qdisc replace dev eth0 parent 1:10 handle 10: fq_codel
      tc qdisc replace dev eth0 parent 1:20 handle 20: fq_codel
      tc filter replace dev eth0 parent 1: protocol ip prio 1 handle 1 flower \
        ip_proto udp src_port 51821-${toString (51820 + lib.length (lib.attrNames nodes))} classid 1:20
    '';
    preStop = "tc qdisc del dev eth0 root || true";
  };
  # 179 is BGP. 5000 is nix-serve: nixkube on sg1 substitutes from
  # dynhetz's store, as nixlab3 does, at the tunnel address a3:3:0:fe.
  networking.firewall.interfaces."wg-sg1+".allowedTCPPorts = [
    179
    5000
  ];
  # BFD for the node sessions.
  networking.firewall.interfaces."wg-sg1+".allowedUDPPorts = [ 3784 ];
  services.frr.bfdd.enable = true;

  networking.nat.internalInterfaces = [ "wg-sg1+" ];

  # The sg1 apiserver on the public IPv4, for a person's kubeconfig
  # (kubernetes.sg1.ch.se.eu.org; solid-kubernetes environments/sg1/
  # api-server.nix). The IPv4 VIP is announced by Cilium, and the nodes'
  # default route comes back through here, so a DNAT alone returns. IPv6
  # needs none: the IPv6 VIP sits in a2::/112, forwarded below.
  networking.nat.forwardPorts = [
    {
      sourcePort = 6443;
      proto = "tcp";
      destination = "10.247.100.10:6443";
      loopbackIPs = [ "37.27.129.237" ];
    }
  ]
  # Pangolin's Gerbil on sg1: WireGuard for sites, and the relay. UDP, so
  # HAProxy cannot carry it. 51830 because this host's own WireGuard holds
  # 51820 (solid-kubernetes environments/sg1/kubernetes/pangolin.nix).
  ++ map
    (port: {
      sourcePort = port;
      proto = "udp";
      destination = "10.247.100.30:${toString port}";
    })
    [
      51830
      21820
    ];
  # Nothing reaches SG1 with this host's public IPv4 as its source: the nodes
  # route 37.27.129.237, their WireGuard endpoint, out of eno1, so the reply
  # never comes back through the tunnel. Measured: the VIP answered from
  # 10.247.102.0 and timed out from 37.27.129.237 (2026-10-29). That source
  # is what a local connection to the public IPv4 gets, and the hairpin SNAT
  # above it gives too. 10.247.102.254 is on every tunnel. -I: before the
  # hairpin SNAT, which would otherwise match first.
  networking.nat.extraCommands = ''
    iptables -w -t nat -I nixos-nat-post -s 37.27.129.237 -o wg-sg1+ -j SNAT --to-source 10.247.102.254
  '';

  # TCPMSS before the ACCEPTs: a terminal ACCEPT ends the chain, so a clamp
  # after it never runs. Pods use MTU 8890 and the tunnel 1420; clamp-to-pmtu
  # on the way out would pick eth0's 1500, so outbound SYNs get a fixed MSS.
  networking.firewall.extraCommands = ''
    iptables -A FORWARD -i wg-sg1+ -p tcp --tcp-flags SYN,RST SYN -m tcpmss --mss 1381:65535 -j TCPMSS --set-mss 1380
    ip6tables -A FORWARD -i wg-sg1+ -p tcp --tcp-flags SYN,RST SYN -m tcpmss --mss 1361:65535 -j TCPMSS --set-mss 1360
    ip46tables -A FORWARD -o wg-sg1+ -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    ip46tables -A FORWARD -i wg-sg1+ -o eth0 -j ACCEPT
    ip46tables -A FORWARD -i eth0 -o wg-sg1+ -m state --state ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A FORWARD -i eth0 -o wg-sg1+ -d 2a01:4f9:3071:11d7:a2::/112 -j ACCEPT
    iptables -A FORWARD -i eth0 -o wg-sg1+ -d 10.247.100.10 -p tcp --dport 6443 -j ACCEPT
    iptables -A FORWARD -i eth0 -o wg-sg1+ -d 10.247.100.30 -p udp -m multiport --dports 51830,21820 -j ACCEPT
    ip46tables -A FORWARD -i wg-dynhetz -o wg-sg1+ -j ACCEPT
    ip46tables -A FORWARD -i wg-sg1+ -o wg-dynhetz -j ACCEPT
  '';

  # After guest-routing.nix, which opens the file with `frr defaults` and
  # `no bgp default ipv4-unicast`. Re-entering `router bgp` adds to it.
  # announce-nothing comes from there too; default-originate bypasses it.
  services.frr.config = lib.mkAfter ''
    ip prefix-list sg1-in4 seq 10 permit 10.247.100.0/24 le 32
    ip prefix-list sg1-in4 seq 20 permit 10.248.0.0/16 le 32
    ipv6 prefix-list sg1-in6 seq 10 permit 2a01:4f9:3071:11d7:a0::/76 le 128
    route-map sg1-in4 permit 10
     match ip address prefix-list sg1-in4
    route-map sg1-in6 permit 10
     match ipv6 address prefix-list sg1-in6
    !
    ! Must match the nodes' profile (solid-kubernetes
    ! environments/sg1/nixos/modules/uplink.nix). Slow, because the
    ! tunnels cross the internet.
    bfd
     profile uplink
      receive-interval 1000
      transmit-interval 1000
      detect-multiplier 3
    !
    router bgp 64512
     ! `frr defaults traditional` leaves this off, so a session that
     ! drops leaves no trace in the journal.
     bgp log-neighbor-changes
     ! Each node announces the VIP from its own ASN; without this FRR keeps
     ! one path and never spreads over the three.
     bgp bestpath as-path multipath-relax
     neighbor sg1-node4 peer-group
     neighbor sg1-node4 remote-as external
     neighbor sg1-node6 peer-group
     neighbor sg1-node6 remote-as external
     neighbor sg1-cilium4 peer-group
     neighbor sg1-cilium4 remote-as external
     neighbor sg1-cilium4 ebgp-multihop 2
     neighbor sg1-cilium6 peer-group
     neighbor sg1-cilium6 remote-as external
     neighbor sg1-cilium6 ebgp-multihop 2
     ! Both sides dial in. Without passive, FRR dials a peer that graceful
     ! restart holds, and Cilium's host firewall drops it as world.
     neighbor sg1-node4 passive
     neighbor sg1-node6 passive
     neighbor sg1-node4 bfd profile uplink
     neighbor sg1-node6 bfd profile uplink
     neighbor sg1-cilium4 passive
     neighbor sg1-cilium6 passive
     bgp listen range 10.247.102.0/24 peer-group sg1-node4
     bgp listen range ${v6}:3::/112 peer-group sg1-node6
     bgp listen range 10.247.100.0/24 peer-group sg1-cilium4
     bgp listen range ${v6}::/112 peer-group sg1-cilium6
     address-family ipv4 unicast
      maximum-paths 8
      neighbor sg1-node4 activate
      neighbor sg1-node4 default-originate
      neighbor sg1-node4 route-map sg1-in4 in
      neighbor sg1-node4 route-map announce-nothing out
      neighbor sg1-cilium4 activate
      neighbor sg1-cilium4 route-map sg1-in4 in
      neighbor sg1-cilium4 route-map announce-nothing out
     exit-address-family
     address-family ipv6 unicast
      maximum-paths 8
      neighbor sg1-node6 activate
      neighbor sg1-node6 default-originate
      neighbor sg1-node6 route-map sg1-in6 in
      neighbor sg1-node6 route-map announce-nothing out
      neighbor sg1-cilium6 activate
      neighbor sg1-cilium6 route-map sg1-in6 in
      neighbor sg1-cilium6 route-map announce-nothing out
     exit-address-family
    !
  '';

  # SSH straight to each node's loopback over its tunnel. The management
  # addresses (10.247.101.x on the GX10s) answer only via oobtik and a jump.
  programs.ssh.knownHosts = lib.mapAttrs' (
    n: name:
    lib.nameValuePair name {
      hostNames = [
        name
        "10.247.100.${n}"
        "${v6}::${n}"
      ];
      publicKey = hostKeys.${name};
    }
  ) names;
  programs.ssh.extraConfig = lib.concatStrings (
    lib.mapAttrsToList (n: name: ''
      Host ${name}
        HostName 10.247.100.${n}
        User root
    '') names
  );
}
