# Routes to the pods of guest clusters, learned over BGP.
#
# A guest cluster's nodes sit on ./vm-network.nix's bridge and its pods live
# behind them, one sub-prefix per node out of the /80 ../wireguard.nix's table
# gives that cluster. So this host has to be told which node owns which
# sub-prefix, and it is the only direction that needs telling: a guest's own
# egress works off the static default route in its machine configuration,
# whether this daemon is running or not. What a session carries is the return
# half.
#
# Why not static routes
# ---------------------
# kube-controller-manager assigns each node its pod sub-prefix in registration
# order, so a rebuilt node comes back owning a different one. A static route
# would then point at the wrong node and keep doing so silently. A session
# withdraws when the node goes and re-announces what the new node actually
# owns, which is the property that makes this worth a routing daemon.
#
# One session per node, not per cluster, for the same reason: the route for a
# node's pods must name that node as its next hop, and only a session with that
# node can say so.
#
# Nothing is announced back
# -------------------------
# Cilium's BGP control plane is advertise-only -- it does not install received
# routes into the kernel, by design rather than omission (cilium/cilium#31091
# and #23464 ask for the capability). A default route offered here would be
# received, listed, and never used.
#
# It could not be the source of a guest's default anyway. BGP there is spoken
# by Cilium, and Cilium is an image the node pulls over its default route
# before it can run. Static default, then pull, then BGP; inverted, nothing
# starts.
{
  config,
  lib,
  ...
}:
let
  network = import ./network.nix;

  # Private 16-bit ASNs, one per cluster. eBGP, because two administrative
  # domains that share a bridge are still two domains.
  hostASN = 64512;

  # Each guest cluster: what it may announce, and who may announce it.
  #
  # `peers` are node addresses chosen by whoever declares the machines -- see
  # ./network.nix's `vmSubnet` for why a guest node's address is chosen rather
  # than allocated. Adding a node here is what admits it; a machine on the
  # bridge with no entry gets no session.
  guests = [
    {
      name = "nixlab2";
      asn = 64513;
      podSubnet = "2a01:4f9:3071:11d7:d0::/80";
      peers = [
        "2a01:4f9:3071:11d7:c0::10"
        "2a01:4f9:3071:11d7:c0::11"
      ];
    }
  ];

  # The inbound filter is a security control, not tidiness. Without it a guest
  # cluster -- misconfigured or compromised -- could announce this host's own
  # pod prefix, or ::/0, and this host would install it and hand that traffic
  # to a virtual machine. Each guest is confined to the prefix the allocation
  # table gives it, and `le 128` admits the per-node sub-prefixes inside it.
  guestPolicy = guest: ''
    ipv6 prefix-list ${guest.name}-pods seq 10 permit ${guest.podSubnet} le 128
    route-map ${guest.name}-in permit 10
     match ipv6 address prefix-list ${guest.name}-pods
    !
  '';

  # Double-quoted rather than '' blocks. Nix strips the common leading
  # whitespace inside every indented string, including a nested one, so an ''
  # block here loses exactly the indentation that shows which lines sit inside
  # the `router bgp` and `address-family` contexts. FRR parses by context and
  # not by column, so it would read either -- but a routing configuration
  # nobody can see the shape of is one nobody can check.
  neighbourLines =
    guest:
    lib.concatMapStrings (
      peer:
      " neighbor ${peer} remote-as ${toString guest.asn}\n"
      + " neighbor ${peer} description ${guest.name}\n"
    ) guest.peers;

  activateLines =
    guest:
    lib.concatMapStrings (
      peer:
      "  neighbor ${peer} activate\n"
      + "  neighbor ${peer} route-map ${guest.name}-in in\n"
      + "  neighbor ${peer} route-map announce-nothing out\n"
    ) guest.peers;
in
{
  config = {
    services.frr.bgpd.enable = true;

    services.frr.config = ''
      frr defaults traditional
      !
      router bgp ${toString hostASN}
       ! A router id is 32 bits and there is no IPv4 address on the interface
       ! these sessions run over, so FRR cannot derive one. eth0's own address
       ! is stable and unique, which is all a router id has to be.
       bgp router-id 37.27.129.237
       ! Every session here is IPv6. Without this FRR activates each neighbour
       ! for IPv4 unicast as well and the session negotiates a family neither
       ! side has anything to say in.
       no bgp default ipv4-unicast
      ${lib.concatMapStrings neighbourLines guests}
       !
       address-family ipv6 unicast
      ${lib.concatMapStrings activateLines guests}
       exit-address-family
      !
      ${lib.concatMapStrings guestPolicy guests}
      ! FRR since 7.4 refuses to exchange anything on an eBGP session that has
      ! no policy, which is a good default and satisfied above -- every
      ! neighbour has a route-map in both directions. This is the outbound one:
      ! nothing is announced to a guest, see the header for why.
      route-map announce-nothing deny 10
      !
    '';

    # BGP is reachable on the bridge the guest nodes are on, and nowhere else.
    # ./vm-network.nix deliberately keeps that bridge out of
    # networking.firewall.trustedInterfaces, so this is stated rather than
    # inherited.
    networking.firewall.interfaces.${network.vmBridge}.allowedTCPPorts = [ 179 ];
  };
}
