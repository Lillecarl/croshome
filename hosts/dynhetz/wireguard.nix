# General-purpose access to dynhetz itself -- not the lab-VPN role
# (../openvpn.nix is the TLS-based one for that, for clients behind
# restrictive firewalls), and not
# scoped to any particular service: this gets each peer (lillecarl's
# MacBook, and a MikroTik router set up as an exit node) a real address
# dynhetz will route to, for whatever dynhetz ends up hosting.
#
# IPv6 is the point, alongside the private IPv4 range every VPN like this
# needs anyway: Hetzner routes dynhetz's whole /64
# (2a01:4f9:3071:11d7::/64) to its link-local gateway (see
# ../default.nix's systemd.network.networks."10-eth0" and its own
# comment) rather than treating it as a shared segment needing NDP proxy
# -- confirmed against Hetzner's own docs, not assumed, since getting
# this wrong would mean traffic for the carved-out range silently never
# arrives. That means a sub-range of it can just be assigned to another
# local interface and routed normally, no proxy-ndp/ndppd needed: giving
# wg-dynhetz 2a01:4f9:3071:11d7:90::1/112 makes the kernel's own
# more-specific connected route carry anything for that /112 there
# automatically, on top of the /64 that already arrives at dynhetz
# unconditionally. Once a peer has a real address in that block, it can
# reach any service dynhetz binds anywhere in the /64 directly -- same
# machine, different interface, no forwarding or NAT involved, since the
# traffic terminates on dynhetz itself rather than passing through it.
#
# Peers deliberately do NOT get a pushed default route (0.0.0.0/0 /
# ::/0) -- only 10.100.0.0/24 and the /64 are routed through the tunnel,
# so this only ever carries traffic to dynhetz itself, never general
# internet traffic. The MikroTik is the exception: as an exit node its
# own script routes everything in, and its server-side allowed-ips is
# 0.0.0.0/0,::/0 to accept those sources. Until this host forwards and
# NATs that traffic (not yet), such packets go nowhere.
#
# Sub-range allocation within the /64, so future networks don't collide
# with this one by accident: each network gets its own /80, chosen by
# the fifth hextet (the first 16 bits after the routed /64).
#
#   2a01:4f9:3071:11d7:0090::/80  -- wg-dynhetz (this file). Only the
#                                    /112 at ::90:: is actually in use.
#   2a01:4f9:3071:11d7:00a0::/80  -- FREE. Was the libvirt lab bridge
#                                    (virbr-nixlab2), for IPv6-only lab VMs.
#                                    That lab is replaced by KubeVirt: the
#                                    bridge is gone, its storage pools are
#                                    undefined and its volume is removed.
#                                    Reuse it before taking a new one.
#   2a01:4f9:3071:11d7:00b0::/80  -- pods of the single-node Kubernetes
#                                    cluster on this host, on cni0. In
#                                    use: ../dynhetz/kubernetes. That
#                                    cluster's Services are ULA
#                                    (fd00:10:96::/108) and take nothing
#                                    from here, because a ClusterIP never
#                                    leaves the node.
#   2a01:4f9:3071:11d7:00c0::/80  -- virtual machines run by KubeVirt in that
#                                    cluster, on the talos0 bridge. In use:
#                                    ../dynhetz/kubernetes/vm-network.nix. A
#                                    machine's address is chosen by whoever
#                                    declares it, not handed out, because a
#                                    Talos node's API certificate names its
#                                    own address and is written before the
#                                    node exists.
#   2a01:4f9:3071:11d7:00d0::/80  -- pods of the first guest cluster on those
#                                    machines (nixlab2). One /80 per guest
#                                    cluster, with its node mask set to /84 so
#                                    each of its nodes gets a real sub-prefix
#                                    and 16 of them fit. The next guest
#                                    cluster takes the /80 after this one.
#   2a01:4f9:3071:11d7:00e0::/80  -- OpenVPN clients on udp/1194, in use:
#                                    ../openvpn.nix. IPv6-only pool, and
#                                    the pushed route for the whole /64 that
#                                    gets a client to everything else here.
#   2a01:4f9:3071:11d7:00e1::/80  -- OpenVPN clients on tcp/443, in use: same
#                                    file. Its own pool because the two server
#                                    instances cannot share one.
#   2a01:4f9:3071:11d7:00e2::/80  -- LoadBalancer services for the nixlab2
#                                    guest cluster. Only the first /112 out of
#                                    it is committed:
#                                    2a01:4f9:3071:11d7:e2::/112. The rest of
#                                    the /80 is free. Like every prefix here,
#                                    the range is unreachable until something
#                                    owns or announces it -- handing the guest
#                                    agent this /112 does not route it.
#
# Guest pods are global addresses out of this table rather than ULA, for the
# same reason the host cluster's are: a pod's source address should be real on
# the way out. The space is not the constraint people assume -- the fifth
# hextet names the /80, so there are 65536 of them, and 4096 even at the
# every-sixteenth spacing this table uses. One per guest cluster costs nothing.
#
# A global prefix here is only half the job. `2a01:4f9:3071:11d7::/64` is a
# connected route on eth0, so an address in it with no more-specific route is
# treated as on-link: the kernel sends a neighbour solicitation onto eth0,
# nothing answers, and the packet is dropped. That applies to the return half
# of an outbound connection too, so a guest pod prefix with no route is not
# "reachable only outbound", it is not reachable at all. Every /80 above works
# because something owns it on a local interface. A guest cluster's pods sit
# behind ../dynhetz/kubernetes/vm-network.nix's bridge instead, one sub-prefix
# per node, so they need a route per node -- which is what a routing daemon on
# this host is for, and there is not one yet.
#
# ../dynhetz/nat64.nix takes nothing from this table. It translates into
# 64:ff9b::/96, which RFC 6052 reserves globally for exactly that, and Jool
# hooks PREROUTING rather than owning an interface -- so there is no device
# here wanting an address of its own.
#
# The next network takes ::00e3::/80 (::00e2::/80's first /112 is taken
# above, its remainder is free).
#
# Not a systemd.network.netdevs entry like ../openvpn.nix's dummy/
# bridge devices: WireGuardPeer's PublicKey has no file-based option in
# systemd's own netdev format (unlike PrivateKeyFile/PresharedKeyFile),
# so it would have to be a literal value baked into this file at Nix
# eval time -- meaning either committing key material to the repo, or a
# separate script writing back into the checkout, neither of which fits
  # "generated once, locally, kept out of the repo" (see ../openvpn.nix
# for the same reasoning applied to its PKI). Configuring the interface
# imperatively via `wg set`, entirely at activation time, sidesteps that.
{ pkgs, ... }:
{
  systemd.services.wireguard-dynhetz = {
    description = "Bring up the dynhetz WireGuard interface (general access)";
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
    script = ''
      set -euo pipefail
      dir=/var/lib/wireguard-dynhetz
      install -d -m 0700 "$dir"
      cd "$dir"

      umask 077
      if [ ! -f server.key ]; then
        wg genkey > server.key
        wg pubkey < server.key > server.pub
      fi
      # Two peers, each with its own keypair and its own `wg set ... peer`
      # line -- WireGuard has no equivalent of a certificate CN multiple
      # peers can share. client.* is lillecarl's MacBook (same
      # "generate once, hand out the whole client config" approach as
      # ../openvpn.nix). mikrotik.* is the MikroTik router: an exit-node
      # client, so it may send from any address -- the NAT and forwarding
      # on this host that make that reachable are a later change.
      if [ ! -f client.key ]; then
        wg genkey > client.key
        wg pubkey < client.key > client.pub
      fi
      if [ ! -f mikrotik.key ]; then
        wg genkey > mikrotik.key
        wg pubkey < mikrotik.key > mikrotik.pub
      fi

      ip link show wg-dynhetz >/dev/null 2>&1 || ip link add wg-dynhetz type wireguard
      wg set wg-dynhetz \
        private-key server.key \
        listen-port 51820 \
        peer "$(cat client.pub)" \
        allowed-ips 10.100.0.2/32,2a01:4f9:3071:11d7:90::2/128 \
        peer "$(cat mikrotik.pub)" \
        allowed-ips 0.0.0.0/0,::/0

      ip addr replace 10.100.0.1/24 dev wg-dynhetz
      ip -6 addr replace 2a01:4f9:3071:11d7:90::1/112 dev wg-dynhetz
      ip link set wg-dynhetz up

      # A ready-to-import wg-quick config -- reassembled every run
      # (cheap), even once the keys themselves are already in place, so
      # it self-heals if it's ever deleted without the keys being
      # touched.
      cat <<EOF > client.conf
      [Interface]
      PrivateKey = $(cat client.key)
      Address = 10.100.0.2/24, 2a01:4f9:3071:11d7:90::2/112

      [Peer]
      PublicKey = $(cat server.pub)
      Endpoint = 37.27.129.237:51820
      AllowedIPs = 10.100.0.0/24, 2a01:4f9:3071:11d7::/64
      PersistentKeepalive = 25
      EOF
      chmod 600 client.conf

      # The MikroTik side as a paste-ready RouterOS 7 script, keys
      # embedded. The default-route lines stay commented: they switch
      # the LAN's internet traffic over, which is pointless until this
      # host NATs it out.
      cat <<EOF > mikrotik.rsc
      /interface/wireguard
      add name=wg-dynhetz mtu=1420 private-key="$(cat mikrotik.key)"
      /interface/wireguard/peers
      add interface=wg-dynhetz name=dynhetz \
          public-key="$(cat server.pub)" \
          endpoint-address=37.27.129.237 endpoint-port=51820 \
          allowed-address=0.0.0.0/0,::/0 persistent-keepalive=25s
      /ip/address
      add interface=wg-dynhetz address=10.100.0.3/24
      /ipv6/address
      add interface=wg-dynhetz address=2a01:4f9:3071:11d7:90::3/112
      # exit-node switch -- the server side (NAT, forwarding) is in
      # place; these two lines route the LAN's internet out through it:
      # /ip/route add dst-address=0.0.0.0/0 gateway=wg-dynhetz
      # /ipv6/route add dst-address=::/0 gateway=wg-dynhetz
      EOF
      chmod 600 mikrotik.rsc
    '';
  };

  networking.firewall.allowedUDPPorts = [ 51820 ];

  # The MikroTik peer is an exit node. networking.nat does the IPv4 half
  # -- MASQUERADE out eth0 for traffic arriving on wg-dynhetz, the
  # matching FORWARD accept, and the forwarding sysctls. The firewall
  # backend here is iptables (see ../libvirt-lab-net.nix), so this chain
  # work is real and not a filterForward no-op.
  #
  # IPv6 does not NAT: the peer's address 2a01:4f9:3071:11d7:90::3 is a
  # real global address out of the routed /64 (see the allocation table
  # above), so forwarded packets leave with their own source and
  # replies ride the /64's connected route back. networking.nat with
  # enableIPv6 off adds no IPv6 rules at all, so the FORWARD accepts
  # come from extraCommands -- trustedInterfaces is INPUT-only on the
  # iptables backend and opens no forwarding.
  #
  # The MSS clamps cover LAN clients behind the MikroTik: they speak
  # 1500-byte Ethernet, the tunnel carries 1420, and without the clamp
  # their SYNs negotiate an MSS the tunnel drops mid-stream.
  networking.nat = {
    enable = true;
    externalInterface = "eth0";
    internalInterfaces = [ "wg-dynhetz" ];
  };

  networking.firewall.extraCommands = ''
    ip46tables -A FORWARD -i wg-dynhetz -o eth0 -j ACCEPT
    ip46tables -A FORWARD -i eth0 -o wg-dynhetz -m state --state ESTABLISHED,RELATED -j ACCEPT
    ip46tables -A FORWARD -i wg-dynhetz -o eth0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    ip46tables -A FORWARD -i eth0 -o wg-dynhetz -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
  '';
}
