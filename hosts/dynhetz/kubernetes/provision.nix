# How this node becomes a cluster.
#
# One oneshot that runs `kubeadm init` exactly once, plus the directories and
# the filesystem attribute that have to exist before it does.
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
    systemd.tmpfiles.rules = [
      "d /etc/kubernetes 0755 root root -"
      "d /etc/kubernetes/manifests 0755 root root -"
      "d /var/lib/kubelet 0755 root root -"
      # Holds this unit's own sentinel. Deliberately not under /var/lib/kubelet
      # or /etc/kubernetes: `kubeadm reset` empties both, and a marker a reset
      # can erase is a marker that cannot survive the failure it exists to
      # describe.
      "d /var/lib/kubernetes 0755 root root -"
    ];

    # etcd measures a cluster in fsync latency, and copy-on-write is the wrong
    # answer for a file rewritten in place all day. / is btrfs here
    # (../disko.nix), so the directory gets the nodatacow attribute before etcd
    # puts anything in it. chattr +C only takes on an empty directory, which is
    # why this runs at activation rather than after the fact -- and why
    # ./kube-nuke.nix has to recreate the directory rather than empty it.
    system.activationScripts.etcd-nodatacow.text = ''
      ${lib.getExe' pkgs.coreutils "mkdir"} --parents /var/lib/etcd
      ${lib.getExe' pkgs.e2fsprogs "chattr"} +C /var/lib/etcd 2>/dev/null || true
    '';

    # `kubeadm init`, run once, and able to recover from its own failure.
    #
    # The marker is a sentinel this unit writes itself, after `kubeadm init`
    # returns 0. That is the whole reason it exists rather than reusing one of
    # kubeadm's own files: every file kubeadm writes is written *during* init,
    # not at the end of it. /var/lib/kubelet/config.yaml -- the obvious choice,
    # and the one that gates kubelet in ./node.nix -- lands in the
    # kubelet-start phase, which is roughly half way. An init that dies after
    # that point leaves a machine that looks provisioned and has no bootstrap
    # token, no uploaded config, no CoreDNS and no kube-proxy, and the next
    # boot skips straight past it. That is the worst state available, so
    # nothing here treats a kubeadm file as proof of anything.
    #
    # Three cases, in the order the script tests them:
    #
    #   sentinel present            done, do nothing.
    #   kube-proxy DaemonSet exists  a finished cluster whose sentinel was
    #                                lost. Adopt it, write the sentinel. The
    #                                addons phase is the last thing init does,
    #                                so that object existing means it finished.
    #   anything else                a failed or partial attempt. Reset, then
    #                                init.
    #
    # The reset is destructive and deliberately so. `kubeadm init` refuses to
    # run over a dirty /etc/kubernetes, so without it a single failed attempt
    # needs a human before the machine can ever converge. It is reachable only
    # when both tests above have said this is not a working cluster.
    #
    # Changing the kubeadm config still does not re-provision anything. It
    # changes what a future init would do. ./kube-nuke.nix is what makes a
    # change take effect on a cluster that already exists.
    systemd.services.kubeadm = {
      description = "kubeadm: provision this machine as a Kubernetes node";
      wantedBy = [ "multi-user.target" ];
      after = [
        "containerd.service"
        "network-online.target"
      ];
      wants = [ "network-online.target" ];
      requires = [ "containerd.service" ];
      # Deliberately no Before=kubelet.service, which deadlocks.
      #
      # kubeadm's kubelet-start phase runs a blocking `systemctl restart
      # kubelet` from inside this script. A Before= here makes kubelet After=
      # this unit, and systemd will not dispatch a job for a unit that is
      # ordered after a unit whose own job is still running. So kubeadm waits
      # on kubelet and kubelet waits on kubeadm, with nothing to detect it.
      # `systemctl list-jobs` is where it shows: this unit "running" and
      # kubelet "waiting", with `[kubelet-start] Starting the kubelet` as the
      # last line in the journal.
      #
      # Nothing is needed in its place. kubelet's ConditionPathExists in
      # ./node.nix is the whole of the ordering, and kubeadm starts kubelet
      # itself.
      path = [
        cfg.package
        pkgs.util-linux
        pkgs.iproute2
        pkgs.iptables
        pkgs.ethtool
        pkgs.socat
        pkgs.conntrack-tools
        pkgs.coreutils
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # A backstop, and only a backstop. The init path's own limits are
        # `timeouts` in ./control-plane.nix's InitConfiguration, and they are
        # what should end a bad run, because kubeadm says what it was waiting
        # for and systemd does not.
        #
        # So this covers the one part those limits do not: pulling the control
        # plane images. That happens in preflight, before any wait kubeadm
        # bounds, and it took 19s here on a cold store. Five minutes leaves
        # room for a slow pull on top of a 90s health check.
        TimeoutStartSec = "5min";
      };
      script = ''
        set -euo pipefail

        sentinel=${cfg.initSentinel}

        adopted() {
          [ -f /etc/kubernetes/admin.conf ] || return 1
          kubectl --kubeconfig /etc/kubernetes/admin.conf \
            --request-timeout=30s -n kube-system get daemonset kube-proxy \
            >/dev/null 2>&1
        }

        if [ -f "$sentinel" ]; then
          echo "kubeadm: already provisioned, nothing to do"
        elif adopted; then
          echo "kubeadm: the cluster is complete but the sentinel was lost; adopting it"
          touch "$sentinel"
        else
          # Anything left from an attempt that did not finish. kubeadm init
          # will not run over it, and reset is the only thing that clears it.
          # Reaching here means neither test above found a working cluster.
          if [ -e /var/lib/kubelet/config.yaml ] \
            || [ -e /etc/kubernetes/admin.conf ] \
            || [ -n "$(ls -A /etc/kubernetes/manifests 2>/dev/null)" ]; then
            echo "kubeadm: a previous init did not finish; resetting first"
            kubeadm reset --force --cri-socket ${cfg.criSocket}
          fi

          kubeadm init --config ${cfg.kubeadmConfig} --skip-token-print
          touch "$sentinel"
        fi

        # kubectl for whoever is on the machine. admin.conf is cluster-admin, so
        # it goes to wheel and no further -- 0640 rather than the 0600 kubeadm
        # leaves behind.
        if [ -f /etc/kubernetes/admin.conf ]; then
          chgrp wheel /etc/kubernetes/admin.conf
          chmod 0640 /etc/kubernetes/admin.conf
        fi
      '';
    };
  };
}
