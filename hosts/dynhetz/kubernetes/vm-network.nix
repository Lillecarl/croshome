# The bridge virtual machines sit on, and the route that makes it reachable.
#
# Why this is host configuration and not a CNI plugin's job
# ---------------------------------------------------------
# The bridge plugin can create a bridge and put a gateway address on it, which
# is what ./runtime.nix's pod network lets it do. This one does not, for one
# reason: a Talos node's address has to exist before the node does.
#
# Its API certificate names its own address and is written when the machine
# configuration is rendered, so the address is chosen by whoever declares the
# machine. That makes the gateway a fixed part of this host rather than
# something a plugin derives from an allocation -- and it has to be up whether
# or not the cluster is, so ../../../kube can be redeployed, or thrown away by
# ./kube-nuke.nix, without the network under the machines going with it.
#
# So networkd owns the bridge and its address, and the
# NetworkAttachmentDefinition in ../../../kube/modules/multus.nix only attaches
# things to it. ./network.nix holds the addresses both of them read.
#
# How a machine on it reaches the world
# -------------------------------------
# The same way a pod does. Hetzner routes the whole /64 to this host rather
# than treating it as a shared segment, so the kernel's connected route for
# ::c0::/80 on this bridge carries the more specific prefix and traffic is
# forwarded in from eth0. No proxy-NDP and no NAT: a machine's source address
# is real on the way out.
#
# IPv6 forwarding is already on -- ./runtime.nix sets it for cni0 and says why
# "default" matters as much as "all" for an interface created after boot. That
# applies here too, and this file deliberately does not set it again: a sysctl
# is a unique option, and two plain definitions of the same value conflict.
{ lib, ... }:
let
  network = import ./network.nix;

  inherit (network) vmBridge vmGateway;

  prefixLength = lib.last (lib.splitString "/" network.vmSubnet);
in
{
  config = {
    systemd.network.netdevs."20-${vmBridge}" = {
      netdevConfig = {
        Name = vmBridge;
        Kind = "bridge";
      };
    };

    # A dummy port, so the bridge has carrier with no machine on it.
    #
    # A bridge is DOWN until something is attached to it, and a DOWN link
    # carries no route -- so the gateway address and the connected route for
    # the prefix would blink out whenever the last machine stopped. That also
    # made systemd-networkd-wait-online fail its two-minute timeout on every
    # boot, because it waits for every link networkd manages.
    #
    # A dummy is the cheapest thing that holds a bridge up: it has carrier
    # whenever it is up, moves no packets, and needs no hardware. The bridge is
    # then genuinely online rather than excused from being checked.
    #
    # It has a second use nothing configures it for. Because this port is the
    # only one this host ever attaches, the bridge's port list answers one
    # question exactly:
    #
    #   ip -br link show master talos0
    #
    # Only the carrier means no machine exists. Any veth beside it means at
    # least one does. That distinction is worth knowing because the tools above
    # this layer hide it: a Terraform `depends_on` between a VirtualMachine
    # object and a bootstrap resource guarantees only that the OBJECT was
    # applied, not that a guest booted. When something upstream fails -- an
    # image import, a scheduler, a volume -- the error surfaces as a bootstrap
    # timeout naming a guest address, which reads exactly like a routing fault
    # on this host and is not one. The port list separates the two from outside
    # the cluster, in one command, with nothing running.
    systemd.network.netdevs."20-${vmBridge}-carrier" = {
      netdevConfig = {
        Name = "${vmBridge}-carrier";
        Kind = "dummy";
      };
    };

    systemd.network.networks."20-${vmBridge}-carrier" = {
      matchConfig.Name = "${vmBridge}-carrier";
      networkConfig.Bridge = vmBridge;
      # The port is a means to the bridge being up, not a thing anything waits
      # for on its own.
      linkConfig.RequiredForOnline = "no";
    };

    systemd.network.networks."20-${vmBridge}" = {
      matchConfig.Name = vmBridge;
      address = [ "${vmGateway}/${prefixLength}" ];
      networkConfig = {
        DHCP = "no";
        # A bridge with no port is DOWN, and a DOWN link carries no route --
        # so without this the gateway address and the connected route for the
        # prefix only exist once a machine is running, which is exactly when
        # they are too late to be useful.
        ConfigureWithoutCarrier = true;
        # Nothing here advertises anything, and nothing here listens to an
        # advertisement. A machine on this bridge is given its address by the
        # object that declares it, never by discovery -- see ./network.nix's
        # `vmSubnet` for why. A router advertisement would offer a second,
        # different answer to a question already settled.
        IPv6AcceptRA = false;
        IPv6SendRA = false;
      };
      # `routable`, and it is reached: the dummy port above gives the bridge
      # carrier, and the address below is static, so nothing here waits on a
      # lease or a peer. Stated rather than left to the default so that a
      # bridge which is NOT up is a failure somebody sees.
      linkConfig.RequiredForOnline = "routable";
    };

    # DNS, and only DNS.
    #
    # A machine here is a guest, not part of this host's cluster, so the bridge
    # is not in networking.firewall.trustedInterfaces the way cni0 is -- there
    # is no reason for a Talos node to reach this host's API server or etcd.
    #
    # It does need the resolver in ../nat64.nix, and needs it specifically:
    # Talos pulls its images from ghcr.io, which has no IPv6 address at all, so
    # a machine here reaches its own installer only through DNS64 and NAT64. A
    # public resolver would answer with nothing usable. ../nat64.nix has the
    # matching access-control entry; both are needed, and either alone fails
    # quietly in a different way.
    networking.firewall.interfaces.${vmBridge} = {
      allowedTCPPorts = [ 53 ];
      allowedUDPPorts = [ 53 ];
    };
  };
}
