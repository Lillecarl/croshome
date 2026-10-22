# kubelet, and the resolver it hands every pod.
#
# The two belong together: kubelet is what reads the file below and copies it
# into each pod's namespace, so changing one without the other is how a cluster
# ends up with a resolver nothing uses.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dynhetz.kubernetes;
in
{
  config = {
    # What every pod gets as its /etc/resolv.conf, and what CoreDNS forwards
    # to. Hetzner's own resolvers, IPv6 only: a pod has no IPv4 address, so
    # the 185.12.64.x pair in ../default.nix would be a timeout here rather
    # than a fallback.
    #
    # mkDefault, for the same reason ./runtime.nix's forwarding sysctls use it:
    # ../nat64.nix replaces these resolvers with a DNS64 in front of them, and
    # two plain definitions of one option are a conflict rather than an
    # override. This file keeps the definition the day that one goes away.
    environment.etc."kubernetes/resolv.conf".text = lib.mkDefault ''
      nameserver 2a01:4ff:ff00::add:1
      nameserver 2a01:4ff:ff00::add:2
    '';

    # kubelet reads /var/lib/kubelet/config.yaml and kubeadm-flags.env, and
    # kubeadm is what writes both. ConditionPathExists is how the unit says so:
    # before provisioning it is skipped, which systemd reports as inactive
    # rather than failed. Started too early it crash-loops instead, and that
    # reads as a broken node rather than an unprovisioned one.
    #
    # It is also the whole of the ordering against kubeadm.service. See
    # ./provision.nix for why a Before=/After= pair there deadlocks instead.
    # Read over kubeadm's config.yaml, which kubeadm writes once at init, so
    # a change here still reaches a provisioned node. Disk eviction at 90%
    # used: images and containers share the root filesystem, and the default
    # imagefs.available<15% evicts pods at 85% on a disk that often runs
    # near there. Setting one evictionHard key zeroes the unnamed ones, so
    # all five are named.
    environment.etc."kubernetes/kubelet.conf.d/50-eviction.conf".text = builtins.toJSON {
      apiVersion = "kubelet.config.k8s.io/v1beta1";
      kind = "KubeletConfiguration";
      evictionHard = {
        "memory.available" = "100Mi";
        "nodefs.available" = "10%";
        "nodefs.inodesFree" = "5%";
        "imagefs.available" = "10%";
        "imagefs.inodesFree" = "5%";
      };
    };

    systemd.services.kubelet = {
      description = "kubelet: the Kubernetes node agent";
      restartTriggers = [ config.environment.etc."kubernetes/kubelet.conf.d/50-eviction.conf".source ];
      wantedBy = [ "multi-user.target" ];
      after = [
        "containerd.service"
        "network-online.target"
      ];
      wants = [ "network-online.target" ];
      requires = [ "containerd.service" ];
      unitConfig.ConditionPathExists = "/var/lib/kubelet/config.yaml";
      # kubelet shells out to all of these: mount and nsenter for volumes,
      # iptables and conntrack for kube-proxy, socat for port-forward.
      path = with pkgs; [
        util-linux
        iproute2
        iptables
        ethtool
        socat
        conntrack-tools
      ];
      environment = {
        KUBELET_KUBECONFIG_ARGS =
          "--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf"
          + " --kubeconfig=/etc/kubernetes/kubelet.conf";
        KUBELET_CONFIG_ARGS =
          "--config=/var/lib/kubelet/config.yaml"
          + " --config-dir=/etc/kubernetes/kubelet.conf.d";
      };
      serviceConfig = {
        # Written by kubeadm, so absent until it has run -- hence the leading
        # dash. It carries --container-runtime-endpoint and the node's pod
        # infra image, which is why kubelet cannot simply be given flags here.
        EnvironmentFile = [ "-/var/lib/kubelet/kubeadm-flags.env" ];
        ExecStart =
          "${lib.getExe' cfg.package "kubelet"} $KUBELET_KUBECONFIG_ARGS"
          + " $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS";
        Restart = "always";
        RestartSec = 5;
        LimitNOFILE = 1048576;
        TasksMax = "infinity";
      };
    };
  };
}
