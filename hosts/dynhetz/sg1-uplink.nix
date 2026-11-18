# Uplink for the SG1 lab cluster (Dynamist): one WireGuard tunnel to
# sg1-wgt, SG1's terminator (solid-kubernetes
# environments/sg1/nixos/modules/terminator-routing.nix), with BGP over it.
# Self-contained so it can be deleted whole: it only adds to options other
# files own (FRR config, NAT, firewall).
#
# SG1's egress and public services, IPv4 and IPv6, go through sg1-router;
# dynhetz gives only the VPN into SG1. The nodes have no tunnels.
#
# The tunnel keeps the old per-node scheme as peer 9: wg-sg1-n9 listens on
# 51829, dynhetz holds 10.247.102.16/31 and :a3:3::10/127. 10.247.102.254
# and :a3:3::fe sit on it too; :a3:3::fe is where nixkube on SG1 reaches
# nix-serve.
{ lib, pkgs, ... }:
let
  # SG1's underlay in its floating /64 (solid-kubernetes
  # environments/sg1/ipv6.nix): node loopbacks at ::n, tunnels at :3::.
  v6 = "2a01:4f9:c01f:4a67:a3";
  # The tunnel's addresses in this host's own /64 before SG1 moved them.
  old6 = "2a01:4f9:3071:11d7:a3";
  peers."9" = "cZKsQKZZKUhes/aHWTbKE6n9f4qA3jJmiH2qTofK60Q=";
  # Up to the highest index, not the count: indexes have gaps.
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
      ip -6 addr del ${old6}:3::${lib.toHexString k}/127 dev ${dev} 2>/dev/null || true
      ip -6 addr del ${old6}:3::fe/128 dev ${dev} 2>/dev/null || true
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
      ${lib.concatStrings (lib.mapAttrsToList tunnel peers)}
      # A tunnel that left `peers` stays up until removed.
      for dev in $(ip -o link show type wireguard | grep -o 'wg-sg1-n[0-9]*'); do
        case $dev in
          ${lib.concatMapStringsSep "|" (n: "wg-sg1-n${n}") (lib.attrNames peers)}) ;;
          *) ip link del "$dev" ;;
        esac
      done
    '';
  };

  networking.firewall.allowedUDPPorts = map (n: 51820 + lib.toInt n) (lib.attrNames peers);

  # 179 is BGP. 5000 is nix-serve: nixkube on sg1 substitutes from
  # dynhetz's store, as nixlab3 does, at the tunnel address a3:3:0:fe.
  networking.firewall.interfaces."wg-sg1+".allowedTCPPorts = [
    179
    5000
  ];

  networking.nat.internalInterfaces = [ "wg-sg1+" ];

  # The sg1 apiserver and Pangolin's Gerbil reach the internet on SG1's own
  # public IPv4, which sg1-router forwards (solid-kubernetes
  # environments/sg1/edge.nix): the nodes' IPv4 default is sg1-router, so a
  # DNAT here would be answered from the wrong address.
  # Nothing reaches SG1 with this host's public IPv4 as its source: SG1's
  # default is sg1-router, so the reply never comes back through the
  # tunnel. Measured: the VIP answered from
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
    ip46tables -A FORWARD -i wg-dynhetz -o wg-sg1+ -j ACCEPT
    ip46tables -A FORWARD -i wg-sg1+ -o wg-dynhetz -j ACCEPT
  '';

  # After guest-routing.nix, which opens the file with `frr defaults` and
  # `no bgp default ipv4-unicast`. Re-entering `router bgp` adds to it.
  # announce-nothing comes from there too; default-originate bypasses it.
  services.frr.config = lib.mkAfter ''
    ip prefix-list sg1-in4 seq 10 permit 10.247.100.0/24 le 32
    ip prefix-list sg1-in4 seq 20 permit 10.248.0.0/16 le 32
    route-map sg1-in4 permit 10
     match ip address prefix-list sg1-in4
    ! SG1's IPv6 is routed by sg1-router, not here.
    route-map sg1-in6 deny 10
    ! The VPN (wireguard.nix), so SG1 answers the operator here, not by
    ! sg1-router, which drops it.
    ip prefix-list sg1-out4 seq 10 permit 10.100.0.0/24
    route-map sg1-out4 permit 10
     match ip address prefix-list sg1-out4
    !
    router bgp 64512
     ! `frr defaults traditional` leaves this off, so a session that
     ! drops leaves no trace in the journal.
     bgp log-neighbor-changes
     ! sg1-wgt carries all of SG1 over one tunnel. Its sessions ride out
     ! loss instead of failing fast: no BFD, a long hold, graceful restart
     ! and long-lived graceful restart (solid-kubernetes
     ! environments/sg1/nixos/modules/terminator-routing.nix).
     bgp graceful-restart restart-time 60
     bgp graceful-restart stalepath-time 300
     ! A restarted bgpd leaves the kernel's routes in place; without this
     ! its OPEN says otherwise and the helper flushes at once.
     bgp graceful-restart preserve-fw-state
     ! A restarted bgpd picks no best path until every graceful-restart
     ! peer sent End-of-RIB, 360 s by default: with sg1-wgt down, the
     ! nodes would wait that long too.
     bgp graceful-restart select-defer-time 10
     bgp long-lived-graceful-restart stale-time 3600
     neighbor sg1-ll4 peer-group
     neighbor sg1-ll4 remote-as external
     neighbor sg1-ll4 timers 20 120
     neighbor sg1-ll4 graceful-restart
     neighbor sg1-ll6 peer-group
     neighbor sg1-ll6 remote-as external
     neighbor sg1-ll6 timers 20 120
     neighbor sg1-ll6 graceful-restart
     neighbor 10.247.102.17 peer-group sg1-ll4
     neighbor ${v6}:3::11 peer-group sg1-ll6
     address-family ipv4 unicast
      maximum-paths 8
      network 10.100.0.0/24
      ! No IPv4 default: SG1 takes it from sg1-router.
      neighbor sg1-ll4 activate
      neighbor sg1-ll4 route-map sg1-in4 in
      neighbor sg1-ll4 route-map sg1-out4 out
     exit-address-family
     address-family ipv6 unicast
      maximum-paths 8
      neighbor sg1-ll6 activate
      neighbor sg1-ll6 route-map sg1-in6 in
      neighbor sg1-ll6 route-map announce-nothing out
     exit-address-family
    !
  '';

  # SSH straight to each node's loopback through sg1-wgt. The management
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
