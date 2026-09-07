# The pod network, as data rather than as files.
#
# Two evaluations need the same values and neither can read the other's
# `config`. This directory is a NixOS module; ../../../kube is a separate
# module system with its own `pkgs`, imported by ../../../default.nix's
# `cluster` attribute. So what both sides must agree on lives here, in a plain
# file that returns an attribute set, and each side imports it.
#
# Without it the pod network is written twice: once as the file containerd
# reads at /etc/cni/net.d, and once as the NetworkAttachmentDefinition that
# multus-daemon delegates to. Two copies of a subnet is one copy too many, and
# nothing would report the day they stopped matching.
#
# This file takes no arguments and reads no `pkgs`, which is what lets both
# sides import it without either one becoming the other's dependency.
rec {
  # Addresses pods get. The option in ./default.nix documents the choice and
  # takes its default from here; this file is the definition because ../../../kube
  # needs the same string and cannot read a NixOS option.
  podSubnet = "2a01:4f9:3071:11d7:b0::/80";

  # The pod network, written from Nix rather than after the fact.
  #
  # A multi-node cluster cannot do this: kube-controller-manager carves a
  # subnet per node out of the pod subnet, and no node knows its own until the
  # cluster exists. Here there is one node and it gets the whole /80, so the
  # value is known at eval time.
  #
  # isDefaultGateway implies isGateway and makes the bridge plugin add the
  # pod's default route itself, through the gateway it derives from the range
  # -- the first address of the pod subnet, which it puts on cni0. Naming ::/0
  # in ipam.routes as well -- which most published conflists do -- adds it
  # twice: the plugin only recognises an existing default route as its own if
  # that route names a gateway, and an ipam route does not, so the second
  # netlink add returns EEXIST and no pod ever gets a sandbox.
  #
  # ipMasq is off. The whole point of spending a routable /80 is that a pod's
  # source address is real on the way out.
  pod = {
    cniVersion = "1.0.0";
    name = "dynhetz";
    plugins = [
      {
        type = "bridge";
        bridge = "cni0";
        isDefaultGateway = true;
        hairpinMode = true;
        ipMasq = false;
        ipam = {
          type = "host-local";
          ranges = [ [ { subnet = podSubnet; } ] ];
        };
      }
      {
        type = "portmap";
        capabilities.portMappings = true;
      }
    ];
  };

  # What containerd calls instead, once multus is deployed.
  #
  # This is the whole of the "thick" client. It names no delegate and no
  # subnet: multus-shim opens a unix socket to multus-daemon, hands the request
  # over, and the daemon decides what to run. That is why this one can be a
  # constant while `pod` above carries the addresses.
  #
  # A plain `.conf` and not a `.conflist`, matching upstream's own
  # deployments/multus-daemonset-thick.yml. The name is the one the daemon
  # gives itself -- MultusDefaultNetworkName in pkg/server/config/manager.go --
  # and a different one here makes the two disagree about which network a pod
  # is on.
  #
  # `capabilities` is not optional. A capability reaches a plugin only if that
  # plugin declares it, and multus is the plugin containerd talks to. Without
  # this line the port mappings stop here, and the portmap plugin in `pod`
  # above is never given any to install.
  multusShim = {
    cniVersion = "1.0.0";
    name = "multus-cni-network";
    type = "multus-shim";
    capabilities.portMappings = true;
    logLevel = "verbose";
    logToStderr = true;
  };
}
