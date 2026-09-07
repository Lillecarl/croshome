# NAT64 and DNS64, so an IPv6-only pod can reach an IPv4-only host.
#
# ./kubernetes.nix gives every pod a real, world-routable IPv6 address and no
# IPv4 address at all. That is the right shape, and it costs the cluster
# github.com, ghcr.io, and every other host that never turned IPv6 on. Image
# pulls do not care, because containerd runs on the host and the host is
# dual-stack. Anything a pod dials itself does care.
#
# Two halves, and neither is useful alone:
#
#   DNS64   invents an IPv6 address for a name that only has an A record. The
#           address encodes the IPv4 one inside 64:ff9b::/96.
#   NAT64   receives traffic sent to 64:ff9b::/96, digs the IPv4 address back
#           out, and forwards it as real IPv4.
#
# DNS64 without NAT64 is worse than neither: it answers every A-only name with
# an address that goes nowhere, so a clean "no AAAA" failure becomes a
# connection timeout. They are one change and they ship together.
#
# 64:ff9b::/96 is the well-known prefix from RFC 6052. Nothing here has to
# allocate for it -- it is reserved globally for exactly this.
#
# Why Tayga and not Jool
# ----------------------
# Jool is the better NAT64. It is stateful, so many pods share one IPv4
# address the way a home router shares one, and nixpkgs has a module for it
# with a build-time config check.
#
# It does not build here. Jool is an out-of-tree kernel module, and 4.1.14
# against this host's 7.2.0 kernel fails at link:
#
#   ERROR: modpost: "snmp_fold_field" [jool_common.ko] undefined!
#
# The kernel stopped exporting that symbol. Checked by building
# `dynhetz.config.boot.kernelPackages.jool` directly rather than by reading a
# changelog. Revisit when Jool releases a build that tracks this kernel;
# `services.tayga` below is then one attribute set to replace, and the DNS64
# half does not move at all.
#
# Tayga is userspace and needs no module. The cost is that it is *stateless*:
# it hands each IPv6 source its own IPv4 address out of a pool, one for one,
# rather than multiplexing them onto ports of a single address. A pool of
# world-routable IPv4 is not something this host has, so the pool is private
# and a second translation follows it:
#
#   pod  --IPv6-->  tayga  --IPv4 from 192.168.255.0/24-->  masquerade
#     -->  37.27.129.237  -->  the internet
#
# That is a NAT64 followed by an ordinary NAT44. Two translations where Jool
# would do one, and the pool caps concurrent pods at ~254. For a single-node
# lab cluster that is not a limit anyone will reach.
{ ... }:
let
  # RFC 6052's well-known prefix. The one value both halves have to agree on:
  # DNS64 writes addresses into it, NAT64 listens for them.
  nat64Prefix = "64:ff9b::/96";

  # See the allocation table in ./wireguard.nix. Keep the two in step.
  # The tun device needs an address of its own, for the ICMPv6 errors Tayga
  # sends back to a pod when a translation fails.
  nat64Address = "2a01:4f9:3071:11d7:c0::1";

  # The private IPv4 that Tayga hands out, one address per pod, and the address
  # Tayga answers as. Free on this host: ./libvirt.nix has 192.168.122.0/24,
  # ./openvpn-oob.nix has 192.168.90.0/24 and 192.168.91.0/24, and ./wireguard.nix
  # has 10.100.0.0/24. Nothing routes this prefix; the masquerade below is the
  # only way a packet with one of these addresses leaves the host.
  nat64Pool = "192.168.255.0";
  nat64PoolPrefixLength = 24;
  taygaAddress = "192.168.255.1";

  # eth0's addresses, named rather than discovered, for the same reason
  # ./kubernetes.nix names the node address: this host has several of each
  # family and the right one is not the one a rule picks by default.
  nodeIP = "2a01:4f9:3071:11d7::2";
  nodeIPv4 = "37.27.129.237";

  # ./kubernetes.nix's pod subnet. The only clients this resolver serves.
  podSubnet = "2a01:4f9:3071:11d7:b0::/80";

  # Hetzner's own resolvers, IPv6 only. The same pair ./kubernetes.nix used to
  # hand pods directly, before this file put a DNS64 in front of them.
  upstream = [
    "2a01:4ff:ff00::add:1"
    "2a01:4ff:ff00::add:2"
  ];
in
{
  config = {
    # ── NAT64: 64:ff9b::/96 in, IPv4 out ─────────────────────────────────

    # The module creates the tun device, puts both router addresses on it, and
    # routes 64:ff9b::/96 and the IPv4 pool into it. That last part is what
    # makes a pod's packet arrive here at all: a pod's default route already
    # points at cni0's gateway, which is this host, and this host then has a
    # route for the prefix instead of an ICMP "no route to host".
    services.tayga = {
      enable = true;
      # wkpfStrict is left at its default of true. It refuses to translate the
      # well-known prefix onto a non-global IPv4 address, which is RFC 6052's
      # own rule and also the thing that stops a pod reaching this host's
      # 192.168.0.0/16 and 10.0.0.0/8 networks -- the libvirt lab, the OpenVPN
      # tunnels, the WireGuard subnet -- by writing their addresses into
      # 64:ff9b::/96 by hand.
      # One address serves as both Tayga's own identity and the address on the
      # tun device. That has a consequence worth knowing before it wastes an
      # afternoon: Tayga will not translate a packet whose source is its own
      # address, and this host's route to 64:ff9b::/96 points out the tun
      # device, so a plain `ping 64:ff9b::1.1.1.1` FROM DYNHETZ ITSELF picks
      # that address as its source and is dropped in silence.
      #
      # That is not a broken translator. Naming any other local address proves
      # it, and both were measured:
      #
      #   ping -6 64:ff9b::1.1.1.1                        100% loss
      #   ping -6 -I 2a01:4f9:3071:11d7::2 64:ff9b::1.1.1.1   0% loss, 1.3ms
      #
      # A pod is never affected. Its packets arrive with the pod's own source
      # address and are forwarded, not generated, here.
      ipv6 = {
        address = nat64Address;
        router.address = nat64Address;
        pool = {
          address = "64:ff9b::";
          prefixLength = 96;
        };
      };
      ipv4 = {
        address = taygaAddress;
        router.address = taygaAddress;
        pool = {
          address = nat64Pool;
          prefixLength = nat64PoolPrefixLength;
        };
      };
    };

    # The NAT44 half. Tayga emits packets from 192.168.255.0/24, which no
    # upstream router has ever heard of, so they need this host's own address
    # before they leave.
    #
    # enableIPv6 stays off, and that is deliberate rather than incidental. This
    # host forwards IPv6 without translating it -- that is the whole point of
    # the routed /64, and ./libvirt-lab-net.nix explains at length why FORWARD
    # is left at ACCEPT here. With enableIPv6 false the module writes no IPv6
    # sysctl and no IPv6 rule, so it cannot disturb any of that. It also adds
    # nothing to the FORWARD chain unless forwardPorts is used, which it is
    # not.
    networking.nat = {
      enable = true;
      enableIPv6 = false;
      externalInterface = "eth0";
      externalIP = nodeIPv4;
      internalIPs = [ "${nat64Pool}/${toString nat64PoolPrefixLength}" ];
    };

    # ── DNS64: an AAAA for a name that has none ──────────────────────────

    # unbound, and not the CoreDNS already running in the cluster, which has a
    # dns64 plugin of its own. CoreDNS's Corefile is a ConfigMap that kubeadm
    # writes during `kubeadm init`, so configuring it from here means either
    # patching a live object at activation time or forking the addon. Both put
    # cluster state in Nix's hands and lose it on the next `kubeadm reset`.
    #
    # Every pod's resolver path already runs through a file this host owns
    # (/etc/kubernetes/resolv.conf, redefined below), so putting the DNS64
    # behind that file needs nothing from the cluster at all.
    services.unbound = {
      enable = true;
      # Off, or unbound becomes the host's own resolver through resolved. The
      # host is dual-stack and wants ordinary answers; only pods want
      # synthesized ones.
      resolveLocalQueries = false;
      # Nothing validates here, so an anchor would only be a file to maintain.
      # The upstreams below validate on their own behalf.
      enableRootTrustAnchor = false;
      settings = {
        server = {
          # The node address, because that is the address a pod can reach: a
          # pod's route to this host is cni0, and cni0's own address is created
          # by the CNI plugin when the first pod starts, long after unbound.
          interface = [ nodeIP ];
          # unbound would otherwise refuse to start until networkd has put the
          # address on eth0.
          ip-freebind = true;

          # Two layers keep this off the internet, because an open resolver on
          # a public address is an amplifier for somebody else's attack.
          #
          # This one is unbound's: everything is refused but the pods and the
          # host itself. The other is the firewall's -- ./kubernetes.nix trusts
          # cni0 and opens no port on eth0, and 53 is not among the ports it
          # opens, so a query from the internet is dropped before unbound sees
          # it. Neither layer is load-bearing on its own.
          access-control = [
            "::/0 refuse"
            "0.0.0.0/0 refuse"
            "${podSubnet} allow"
            "${nodeIP}/128 allow"
            "::1/128 allow"
          ];

          # The dns64 module runs in front of the iterator and synthesizes only
          # when the real answer comes back with no AAAA. A dual-stack name is
          # returned untouched, which is what keeps this from routing traffic
          # through the translator that never needed to go there.
          module-config = ''"dns64 iterator"'';
          dns64-prefix = nat64Prefix;

          # The upstreams are IPv6, and so is every client.
          do-ip4 = false;
          do-ip6 = true;

          hide-identity = true;
          hide-version = true;
        };

        # Forward rather than recurse. Hetzner's resolvers are one hop away and
        # already cache for this whole rack.
        forward-zone = [
          {
            name = ".";
            forward-addr = upstream;
          }
        ];
      };
    };

    # What every pod gets as its /etc/resolv.conf, and what CoreDNS forwards
    # to. ./kubernetes.nix names the Hetzner resolvers here with mkDefault, so
    # that it stands on its own the day this file goes away; a plain definition
    # takes over while this file exists. That is the same split the two files
    # already use for the IPv6 forwarding sysctls.
    #
    # A pod picks this file up when it is created, so CoreDNS keeps the old
    # contents until its pods are replaced. `kubectl -n kube-system rollout
    # restart deployment coredns` is the one thing a rebuild does not do for
    # itself.
    environment.etc."kubernetes/resolv.conf".text = ''
      nameserver ${nodeIP}
    '';
  };
}
