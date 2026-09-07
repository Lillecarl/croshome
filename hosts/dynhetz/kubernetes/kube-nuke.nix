# Throw this node's cluster away and provision a new one.
#
# ./provision.nix already knows how to reset a half-finished attempt, so this
# is not a second copy of that logic: it removes the sentinel and the state
# that unit's own tests read, then starts the unit and lets it do the work.
# That way one file describes provisioning and this one only describes
# forgetting.
#
# Three things `kubeadm reset` leaves behind, and each is a real failure rather
# than untidiness:
#
#   the CNI bridge and its leases  host-local records every address it hands
#                                  out. A lease that survives is an address
#                                  the plugin believes is taken, so a rebuilt
#                                  cluster starts on a smaller pool every
#                                  time.
#   kube-proxy's iptables chains   reset prints that it will not touch them.
#   /var/lib/etcd's nodatacow      chattr +C only takes on an empty directory,
#                                  and ./provision.nix's activation script
#                                  that normally sets it runs at switch time,
#                                  not here. Leaving the directory in place is
#                                  how the attribute gets lost for good, and
#                                  nothing afterwards reports that etcd is now
#                                  writing copy-on-write.
#
# ~/.kube/config needs nothing: `kubeadm init` writes a new CA and a new
# admin.conf, and a symlink to that path follows it. A copy would not.
{
  config,
  pkgs,
  ...
}:
let
  cfg = config.dynhetz.kubernetes;

  kube-nuke = pkgs.writeShellApplication {
    name = "kube-nuke";
    runtimeInputs = [
      cfg.package
      pkgs.systemd
      pkgs.coreutils
      pkgs.e2fsprogs
      pkgs.iproute2
      pkgs.iptables
      pkgs.util-linux
      pkgs.ethtool
      pkgs.socat
      pkgs.conntrack-tools
    ];
    text = ''
      if [ "$(id -u)" -ne 0 ]; then
        echo "kube-nuke: this needs root. Run it under sudo." >&2
        exit 1
      fi

      assume_yes=0
      case "''${1-}" in
        "") ;;
        -y | --yes) assume_yes=1 ;;
        *)
          echo "usage: kube-nuke [--yes]" >&2
          exit 2
          ;;
      esac

      if [ "$assume_yes" -eq 0 ]; then
        cat >&2 <<'WARNING'
      kube-nuke destroys this node's Kubernetes cluster and builds a new one.
      etcd goes with it: every workload, every secret, every certificate.
      Nothing here is backed up.
      WARNING
        printf 'Type the hostname (%s) to go ahead: ' ${config.networking.hostName} >&2
        read -r answer
        if [ "$answer" != ${config.networking.hostName} ]; then
          echo "kube-nuke: that does not match. Nothing was touched." >&2
          exit 1
        fi
      fi

      echo "kube-nuke: tearing down"

      # While kube-proxy's own binary can still be asked to. A new kube-proxy
      # reconciles what it finds anyway, so this failing is not fatal.
      kube-proxy --cleanup || true

      systemctl stop kubelet.service || true
      systemctl stop kubeadm.service || true

      # Tolerated: a reset that fails leaves state behind, and kubeadm.service
      # tests for exactly that state and resets again before it inits.
      kubeadm reset --force --cri-socket ${cfg.criSocket} || true

      rm -f ${cfg.initSentinel}

      ip link delete cni0 2>/dev/null || true
      rm -rf /var/lib/cni/networks

      rm -rf /var/lib/etcd
      mkdir -p /var/lib/etcd
      chattr +C /var/lib/etcd 2>/dev/null || true

      echo "kube-nuke: provisioning"
      systemctl start kubeadm.service

      # The unit returning 0 means `kubeadm init` finished. It does not yet
      # mean the node is Ready, so report that separately rather than implying
      # it.
      kubectl --kubeconfig /etc/kubernetes/admin.conf \
        wait --for=condition=Ready node --all --timeout=180s

      kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes
      kubectl --kubeconfig /etc/kubernetes/admin.conf -n kube-system get pods
    '';
  };
in
{
  config.environment.systemPackages = [ kube-nuke ];
}
