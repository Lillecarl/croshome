# Routes to the pods of guest clusters, learned over BGP.
#
# A guest cluster's nodes sit on ./vm-network.nix's bridge and its pods live
# behind them, one sub-prefix per node out of the /80 ../wireguard.nix's table
# gives that cluster. So this host has to be told which node owns which
# sub-prefix, and it is the only direction that needs telling: a guest's own
# egress works off the static default route in its machine configuration,
# whether this daemon is running or not.
#
# What a session carries is the half that reaches *in* -- and that is less
# than it sounds, which is worth knowing before reading a missing route as an
# outage. A guest that masquerades pod egress behind its node address needs no
# route here at all for pods to reach the world: the reply is addressed to the
# node, which is on the bridge and connected. nixlab2 does exactly that
# (enable-ipv6-masquerade, ipv6-native-routing-cidr = its own pod /80), so it
# ran for a day with no pod prefix advertised and nothing visibly wrong,
# NAT64 included. These routes matter for traffic that starts on this side and
# names a pod address.
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
  pkgs,
  ...
}:
let
  network = import ./network.nix;

  # Private 16-bit ASNs, one per cluster. eBGP, because two administrative
  # domains that share a bridge are still two domains.
  hostASN = 64512;

  # Each guest cluster: what it may announce, and who may announce it.
  #
  # `nodeSubnet` is a listen range, not a list of neighbours. Any machine in it
  # that dials this host gets a session, so a node added to the cluster later
  # needs no change here.
  #
  # That is the point of the range. A node absent from a neighbour list peers
  # with nobody, and nothing on this host says so: its Cilium session sits in
  # `active` with 0 routes, and this side simply has one fewer session than the
  # cluster has nodes. Four of nixlab2's five nodes were configured and it went
  # unnoticed, because every LoadBalancer Service used externalTrafficPolicy
  # Cluster -- all four peers advertise such a VIP whatever node the backend is
  # on. The first Service with externalTrafficPolicy Local, whose VIP only the
  # node holding the pod advertises, landed on the fifth node and was
  # unroutable.
  #
  # So what admits a guest is the prefix plus the inbound filter below, not an
  # address list. The prefix is ./network.nix's bridge subnet, which only
  # machines this host declares are on, and the filter confines each session to
  # the prefixes the allocation table gives that cluster. A second guest
  # cluster needs its own sub-range: two listen ranges that overlap leave one
  # machine matching two peer-groups.
  guests = [
    {
      name = "nixlab3";
      asn = 64514;
      podSubnet = "2a01:4f9:3071:11d7:d1::/80";
      # LoadBalancer VIPs, first /112 out of the 00e2::/80 the allocation
      # table in ../wireguard.nix reserves for them.
      lbSubnet = "2a01:4f9:3071:11d7:e2::/112";
      # The whole bridge, because nixlab3 is the only cluster on it. Not the
      # site /64: that also holds the pod prefix, the VIP pool and eth0.
      nodeSubnet = network.vmSubnet;
    }
  ];

  # The inbound filter is a security control, not tidiness. Without it a guest
  # cluster -- misconfigured or compromised -- could announce this host's own
  # pod prefix, or ::/0, and this host would install it and hand that traffic
  # to a virtual machine. Each guest is confined to the prefixes the allocation
  # table gives it, and `le 128` admits the per-node sub-prefixes and the /128
  # VIPs inside them.
  #
  # One prefix-list per `match` line, and one route-map entry per list. This
  # read `match ipv6 address prefix-list <pods> <lb>` for both at once, which
  # FRR does not accept:
  #
  #   line 13: % Unknown command[7]:  match ipv6 address prefix-list nixlab2-pods nixlab2-lb
  #
  # That is the trap. FRR rejects the line and keeps going, so the route-map
  # still exists and still permits -- with no match clause at all, which
  # permits everything. `show route-map nixlab2-in` printed an empty "Match
  # clauses:" while the two prefix-lists sat there correct and unused, and the
  # control this comment describes had never once been applied. A filter that
  # fails open is worse than no filter, because the config reads as if one is
  # there.
  #
  # Two entries, so the list that matches decides: an announcement matching
  # neither falls off the end into the implicit deny.
  guestPolicy = guest: ''
    ipv6 prefix-list ${guest.name}-pods seq 10 permit ${guest.podSubnet} le 128
    ipv6 prefix-list ${guest.name}-lb seq 10 permit ${guest.lbSubnet} le 128
    route-map ${guest.name}-in permit 10
     match ipv6 address prefix-list ${guest.name}-pods
    route-map ${guest.name}-in permit 20
     match ipv6 address prefix-list ${guest.name}-lb
    !
  '';

  # Double-quoted rather than '' blocks. Nix strips the common leading
  # whitespace inside every indented string, including a nested one, so an ''
  # block here loses exactly the indentation that shows which lines sit inside
  # the `router bgp` and `address-family` contexts. FRR parses by context and
  # not by column, so it would read either -- but a routing configuration
  # nobody can see the shape of is one nobody can check.
  # A peer-group and a listen range, one per guest. The settings live on the
  # group, and a machine that dials from inside the range joins it.
  #
  # A dynamic neighbour is passive: this host answers, it never calls. Cilium
  # dials, so every node opens its own session. A machine that never dials gets
  # none, and `show bgp ipv6 unicast summary` is then the only place the
  # absence shows.
  #
  # Order matters to FRR. The group must exist and carry its remote-as before
  # the listen range can name it.
  neighbourLines =
    guest:
    " neighbor ${guest.name} peer-group\n"
    + " neighbor ${guest.name} remote-as ${toString guest.asn}\n"
    + " bgp listen range ${guest.nodeSubnet} peer-group ${guest.name}\n";

  activateLines =
    guest:
    "  neighbor ${guest.name} activate\n"
    + "  neighbor ${guest.name} route-map ${guest.name}-in in\n"
    + "  neighbor ${guest.name} route-map announce-nothing out\n";
in
{
  config = {
    services.frr.bgpd.enable = true;

    # Parse the configuration at build time, because FRR does not fail on a
    # line it cannot parse.
    #
    # It logs `% Unknown command`, drops that line, and carries on with
    # whatever the rest of the file built -- so a rejected `match` left a
    # route-map that permits everything, and the daemon started clean, the
    # sessions came up, and the routes flowed. Nothing about a running system
    # said the filter was missing. `show route-map` did, to somebody who
    # already suspected it.
    #
    # `vtysh --dryrun` parses without touching a kernel or a daemon, so it
    # runs in a sandbox. It exits 0 either way -- checked, both branches --
    # which is why this reads the output rather than the status.
    #
    # system.checks rather than system.extraDependencies: a check has to build
    # before the switch, and this one has no business in the closure
    # afterwards.
    system.checks = [
      (pkgs.runCommand "frr-config-dryrun"
        {
          nativeBuildInputs = [ pkgs.frr ];
          conf = pkgs.writeText "frr-dryrun.conf" config.services.frr.config;
        }
        ''
          # vtysh reads its own vtysh.conf before the input file, and a
          # sandbox has no /etc/frr. Missing, that is "processing failure:
          # 11" -- indistinguishable from a real rejection to a check reading
          # the output, and it failed this derivation on a correct config
          # until an empty one stood in for it.
          mkdir -p etc
          : > etc/vtysh.conf

          report=$(vtysh --config_dir "$PWD/etc" --dryrun --inputfile "$conf" 2>&1 || true)
          printf '%s\n' "$report"
          if printf '%s' "$report" | grep -qE '% Unknown command|processing failure'; then
            echo "" >&2
            echo "FRR rejected a line in services.frr.config, above. It keeps" >&2
            echo "going when it does, so this would have started and run with" >&2
            echo "that line silently absent." >&2
            exit 1
          fi
          touch "$out"
        ''
      )
    ];

    # Policy first, router second. FRR reads this file from top to bottom. A
    # `neighbor ... route-map X` line that names a route-map the file has not
    # defined yet logs "The route-map 'X' does not exist" and leaves the
    # reference unresolved. FRR does resolve it later in the same read, when
    # the route-map appears, so the order below is not the difference between
    # working and broken. It is the difference between a filter that is
    # definitely there and one that is there because a second mechanism caught
    # up -- and this filter decides what a guest cluster can put in this
    # host's routing table. Define it first and the question does not arise.
    services.frr.config = ''
      frr defaults traditional
      !
      ${lib.concatMapStrings guestPolicy guests}
      ! FRR since 7.4 refuses to exchange anything on an eBGP session that has
      ! no policy, which is a good default and satisfied below -- every
      ! neighbour has a route-map in both directions. This is the outbound one:
      ! nothing is announced to a guest, see the header for why.
      route-map announce-nothing deny 10
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
    '';

    # BGP is reachable on the bridge the guest nodes are on, and nowhere else.
    # ./vm-network.nix deliberately keeps that bridge out of
    # networking.firewall.trustedInterfaces, so this is stated rather than
    # inherited.
    networking.firewall.interfaces.${network.vmBridge}.allowedTCPPorts = [ 179 ];
  };
}
