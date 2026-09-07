# dynhetz as a single-node Kubernetes cluster, provisioned by kubeadm.
#
# The cluster exists to host KubeVirt, which in turn hosts the development
# clusters that ../libvirt-lab-net.nix's VMs host today. That migration is not
# this directory. This is the node underneath it: a container runtime, a
# kubeadm bootstrap, a kubelet, and one bridge for pods to sit on.
#
# What is in which file
# ---------------------
#   ./default.nix       this file. The addresses every other one reads, and
#                       the two rules about who may reach the API.
#   ./network.nix       the CNI configurations, as plain data. Not a module:
#                       ../../../kube imports it too, and that is a separate
#                       evaluation which cannot read a NixOS option.
#   ./runtime.nix       containerd, the CNI bridge, and the kernel settings
#                       that make pod traffic behave.
#   ./vm-network.nix    the second bridge, the one virtual machines sit on.
#                       Owned by the host rather than by a CNI plugin,
#                       because a Talos node's address has to exist before
#                       the node does.
#   ./control-plane.nix what the cluster is configured to be: the kubeadm
#                       documents, and the build-time check over them.
#   ./provision.nix     how the node becomes a cluster: kubeadm.service, run
#                       once, able to recover from its own failure.
#   ./node.nix          kubelet, and the resolver it hands every pod.
#   ./kube-nuke.nix     how to throw the cluster away and start again.
#
# The values below are options rather than a `let` block because they are read
# across those files, and by ../nat64.nix, which needs the pod subnet and the
# node address to do its own job. An option is one definition with one name; a
# `let` copied into six files is six things to keep in step, and nothing would
# report the day they stopped matching.
#
# Why kubeadm and not `services.kubernetes`
# -----------------------------------------
# NixOS's own `services.kubernetes` builds a control plane out of Nix, with
# every component as a systemd unit. kubeadm builds the same control plane out
# of static pods, which is what every real cluster looks like and what every
# upstream tool expects to find. The control plane is part of what this machine
# is for learning, so the faithful shape wins over the convenient one.
#
# The cost of that choice is that kubeadm writes state -- certificates,
# kubeconfigs, /var/lib/kubelet/config.yaml -- that Nix does not own. Two units
# carry the split:
#
#   kubeadm.service   a oneshot that runs `kubeadm init` exactly once, and
#                     does nothing on every boot after that. ./provision.nix.
#   kubelet.service   gated on ConditionPathExists, so it stays inactive until
#                     kubeadm has written the config it reads. A kubelet that
#                     starts before that crash-loops, which reads as a broken
#                     node rather than an unprovisioned one. ./node.nix.
#
# Addressing
# ----------
# The cluster is single-stack IPv6. dynhetz has a routed /64 (see
# ../default.nix and ../wireguard.nix's allocation table), and Hetzner routes
# the whole thing here rather than treating it as a shared segment -- so a
# sub-prefix can be handed to another local interface and the kernel's own
# more-specific route carries it, with no proxy-NDP and no NAT. Pods therefore
# get real, world-routable addresses:
#
#   pods      2a01:4f9:3071:11d7:b0::/80   the next free /80 in that table
#   services  fd00:10:96::/108             ULA, never leaves the node
#   node      2a01:4f9:3071:11d7::2        eth0's address
#
# Services are ULA on purpose. A ClusterIP is a virtual address that only
# kube-proxy's DNAT rules ever see, so spending routable space on it buys
# nothing, and Kubernetes caps an IPv6 service CIDR at /108 regardless.
#
# Three constraints here were checked against the kubeadm binary in
# pkgs.kubernetes rather than assumed, because each one fails at `kubeadm init`
# time rather than at eval time:
#
#   - kube-controller-manager's IPv6 node mask defaults to /64, and kubeadm
#     rejects a podSubnet smaller than the node mask. `node-cidr-mask-size-ipv6`
#     is the argument kubeadm reads; the family-neutral `node-cidr-mask-size`
#     is ignored by its validator and the config still fails.
#   - A node mask equal to the pod mask is accepted. One node gets the whole
#     /80, which is what a single-node cluster wants.
#   - The service CIDR must be /108 or smaller. /107 is rejected outright.
#
# ./control-plane.nix turns those three into a build-time check, so a nixpkgs
# bump that moves them fails the rebuild instead of the machine.
#
# What pods cannot reach
# ----------------------
# A pod has no IPv4 address, so an IPv4-only host is unreachable from inside
# the cluster -- github.com and ghcr.io among them. Image pulls are unaffected,
# because containerd runs on the host and the host is dual-stack. NAT64 and
# DNS64 are the answer to the rest, and they live in ../nat64.nix.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dynhetz.kubernetes;

  str =
    description: default:
    lib.mkOption {
      inherit default description;
      internal = true;
      type = lib.types.str;
    };
in
{
  imports = [
    ./runtime.nix
    ./vm-network.nix
    ./guest-routing.nix
    ./control-plane.nix
    ./provision.nix
    ./node.nix
    ./kube-nuke.nix
  ];

  options.dynhetz.kubernetes = {
    package = lib.mkOption {
      internal = true;
      type = lib.types.package;
      default = pkgs.kubernetes;
      description = ''
        The Kubernetes distribution every file here uses. One attribute, so
        kubeadm, kubelet and kubectl can never come from two versions.
      '';
    };

    podSubnet = str ''
      Addresses pods get. See the allocation table in ../wireguard.nix, and
      keep the two in step. Defined in ./network.nix rather than here, because
      ../../../kube needs the same string and cannot read a NixOS option.
    '' (import ./network.nix).podSubnet;

    serviceSubnet = str ''
      Addresses ClusterIPs get. ULA, because a ClusterIP never leaves the node.
    '' "fd00:10:96::/108";

    nodeIP = str ''
      eth0's address, named rather than discovered. kubelet has three global
      IPv6 addresses to choose between on this host (eth0, wg-dynhetz, the
      libvirt lab bridge) and picks by a rule nothing here controls.
    '' "2a01:4f9:3071:11d7::2";

    wgAddress = str ''
      The WireGuard peer address from ../wireguard.nix, which is where kubectl
      runs from when it is not running on dynhetz itself.
    '' "2a01:4f9:3071:11d7:90::1";

    criSocket = str ''
      The CRI endpoint. containerd is configured in ./runtime.nix.
    '' "unix:///run/containerd/containerd.sock";

    sandboxImage = str ''
      containerd builds a pod sandbox without consulting the runtime spec, so
      this image is the one thing it pulls on its own. Its version tracks
      containerd releases by default and has to track kubeadm's instead: the
      two agree today, and the day they stop, every sandbox fails to start over
      an image nothing here mentions. ./control-plane.nix asserts they match.
    '' "registry.k8s.io/pause:3.10.2";

    initSentinel = str ''
      The marker ./provision.nix writes after `kubeadm init` returns 0, and the
      one file ./kube-nuke.nix removes to make the next start provision instead
      of skip.
    '' "/var/lib/kubernetes/kubeadm-init-done";

    kubeadmConfig = lib.mkOption {
      internal = true;
      type = lib.types.path;
      description = ''
        The concatenated kubeadm documents. Set by ./control-plane.nix and read
        by ./provision.nix, which is the only thing that runs `kubeadm init`.
      '';
    };
  };

  config = {
    environment.systemPackages = [
      cfg.package
      pkgs.etcd
    ];

    # kubectl with no arguments, for whoever is on the machine. The file is
    # cluster-admin credentials and ./provision.nix gives it to the wheel
    # group, which on this host is one person.
    environment.variables.KUBECONFIG = "/etc/kubernetes/admin.conf";

    # ── the firewall ─────────────────────────────────────────────────────

    # cni0 is trusted, and this is the rule the cluster does not work without.
    # A pod reaching a ClusterIP is DNATed to the node address and arrives back
    # on cni0 as INPUT. CoreDNS talking to the API server is that path, and so
    # is every controller that will ever run here. Without this the node goes
    # Ready, every pod starts, and nothing inside the cluster can reach the API.
    #
    # ../nat64.nix leans on this too: it is why the DNS64 resolver can listen
    # on a public address without answering the internet.
    networking.firewall.trustedInterfaces = [ "cni0" ];

    # 6443 over WireGuard and nowhere else. kubectl on dynhetz itself reaches
    # the API server over loopback, which the firewall always accepts, because
    # the advertised address is one of this host's own.
    networking.firewall.interfaces."wg-dynhetz".allowedTCPPorts = [ 6443 ];
  };
}
