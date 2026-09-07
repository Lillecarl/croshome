# The container runtime, the pod network, and the kernel settings both need.
#
# Nothing here knows the cluster exists. containerd would run the same way for
# podman, and the bridge would carry the same addresses without a kubelet. That
# is the reason this is its own file: it is the layer a cluster sits on, not
# part of the cluster.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dynhetz.kubernetes;

  json = pkgs.formats.json { };

  # The pod network, written from Nix rather than after the fact.
  #
  # A multi-node cluster cannot do this: kube-controller-manager carves a subnet
  # per node out of the pod subnet, and no node knows its own until the cluster
  # exists. Here there is one node and it gets the whole /80, so the value is
  # known at eval time and the conflist can be a plain file.
  #
  # isDefaultGateway implies isGateway and makes the bridge plugin add the pod's
  # default route itself, through the gateway it derives from the range -- the
  # first address of the pod subnet, which it puts on cni0. Naming ::/0 in
  # ipam.routes as well -- which most published conflists do -- adds it twice:
  # the plugin only recognises an existing default route as its own if that
  # route names a gateway, and an ipam route does not, so the second netlink add
  # returns EEXIST and no pod ever gets a sandbox.
  #
  # ipMasq is off. The whole point of spending a routable /80 is that a pod's
  # source address is real on the way out.
  cniConfig = json.generate "10-dynhetz.conflist" {
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
          ranges = [ [ { subnet = cfg.podSubnet; } ] ];
        };
      }
      {
        type = "portmap";
        capabilities.portMappings = true;
      }
    ];
  };
in
{
  config = {
    virtualisation.containerd = {
      enable = true;
      settings = {
        # containerd 2.x reads a version 2 file by migrating it and warning.
        # Saying 3 outright puts the sections below where they are read rather
        # than where they used to be. The module's own default is 2, and it is
        # a plain value, so it needs mkForce rather than an override.
        version = lib.mkForce 3;
        # Same reason: the module seeds a version 2 CRI section that nothing
        # reads under version 3. An empty table leaves the file clean.
        plugins."io.containerd.grpc.v1.cri" = lib.mkForce { };
        plugins."io.containerd.cri.v1.runtime" = {
          containerd.runtimes.runc.options.SystemdCgroup = true;
          # No copy into /opt/cni/bin. Nothing writes to these binaries and the
          # store path is already on the node. Multus will want the conventional
          # directory when KubeVirt arrives; bin_dirs is a list, so that is one
          # more entry rather than a change of approach.
          cni.bin_dirs = [ "${pkgs.cni-plugins}/bin" ];
          cni.conf_dir = "/etc/cni/net.d";
        };
        plugins."io.containerd.cri.v1.images".pinned_images.sandbox = cfg.sandboxImage;
      };
    };

    boot.kernelModules = [
      "overlay"
      "br_netfilter"
      "nf_conntrack"
    ];

    boot.kernel.sysctl = {
      # Pod-to-pod traffic on one node crosses the CNI bridge. Without these,
      # kube-proxy's rules never see it, so a Service answers from the host and
      # not from the pod beside it.
      "net.bridge.bridge-nf-call-iptables" = 1;
      "net.bridge.bridge-nf-call-ip6tables" = 1;
      # IPv6 forwarding is already on for the libvirt lab bridge -- see
      # ../libvirt-lab-net.nix, which explains why "default" matters as much as
      # "all" for an interface created after boot. cni0 is exactly that case.
      # Repeated here rather than depended on: this must stand on its own the
      # day the libvirt lab goes away. mkDefault because a sysctl is a unique
      # option and two plain definitions of the same value are still a conflict
      # -- so that file keeps the definition while it exists, and this one takes
      # over when it does not.
      "net.ipv6.conf.all.forwarding" = lib.mkDefault 1;
      "net.ipv6.conf.default.forwarding" = lib.mkDefault 1;
      # Nothing in this cluster carries IPv4, but kubeadm's preflight reads
      # /proc/sys/net/ipv4/ip_forward and refuses to run when it is 0. It is 1
      # on this host today only because libvirt set it imperatively at some
      # point, which is not a thing to depend on -- ../libvirt-lab-net.nix's
      # network is on its way out.
      "net.ipv4.ip_forward" = lib.mkDefault 1;
      # Go runtimes reserve far more address space than they touch.
      "vm.overcommit_memory" = 1;
    };

    environment.etc = {
      "cni/net.d/10-dynhetz.conflist".source = cniConfig;

      "crictl.yaml".text = ''
        runtime-endpoint: ${cfg.criSocket}
        image-endpoint: ${cfg.criSocket}
        timeout: 60
      '';
    };

    environment.systemPackages = [
      pkgs.cri-tools
      pkgs.cni-plugins
    ];
  };
}
