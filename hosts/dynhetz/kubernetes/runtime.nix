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

  # ./network.nix says what these are and why they are a separate file.
  network = import ./network.nix;
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
          # store path is already on the node, so a store path is both the
          # binary and the version pin.
          #
          # This is also the reason multus's upstream DaemonSet cannot install
          # itself here: its init container copies multus-shim into
          # /host/opt/cni/bin, a directory this node does not have and would
          # not let it write to. ../../../kube/modules/multus.nix drops that
          # container, because the binary is already on this line.
          cni.bin_dirs = [
            "${pkgs.cni-plugins}/bin"
            "${pkgs.multus-cni}/bin"
          ];
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
      # /etc/cni/net.d is a real directory that root can write to -- only the
      # files below are store symlinks. So multus could place its own config
      # here and upstream's DaemonSet does exactly that. Nix places it instead,
      # for one reason: removing ../../../kube/modules/multus.nix and applying
      # again leaves the file behind, and a 00-multus.conf naming a daemon that
      # is gone stops every pod on the node from starting. A file Nix owns
      # disappears on the next switch.
      #
      # containerd reads the lexically first configuration in this directory,
      # so 00-multus.conf is the default network and 10-dynhetz.conflist is
      # what multus-daemon delegates to -- not directly, but through the
      # NetworkAttachmentDefinition built from the same value. It stays on disk
      # because it is what the node falls back to with no multus at all, which
      # is the state right after ./kube-nuke.nix runs.
      "cni/net.d/00-multus.conf".source = json.generate "00-multus.conf" network.multusShim;
      "cni/net.d/10-dynhetz.conflist".source = json.generate "10-dynhetz.conflist" network.pod;

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
