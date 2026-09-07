# dynhetz as a single-node Kubernetes cluster, provisioned by kubeadm.
#
# The cluster exists to host KubeVirt, which in turn hosts the development
# clusters that ../libvirt-lab-net.nix's VMs host today. That migration is not
# this file. This file is the node underneath it: a container runtime, a
# kubeadm bootstrap, a kubelet, and one bridge for pods to sit on.
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
# below carry the split:
#
#   kubeadm.service   a oneshot that runs `kubeadm init` exactly once, and
#                     does nothing on every boot after that.
#   kubelet.service   gated on ConditionPathExists, so it stays inactive until
#                     kubeadm has written the config it reads. A kubelet that
#                     starts before that crash-loops, which reads as a broken
#                     node rather than an unprovisioned one.
#
# Addressing
# ----------
# The cluster is single-stack IPv6. dynhetz has a routed /64 (see
# ../dynhetz/default.nix and ../dynhetz/wireguard.nix's allocation table), and
# Hetzner routes the whole thing here rather than treating it as a shared
# segment -- so a sub-prefix can be handed to another local interface and the
# kernel's own more-specific route carries it, with no proxy-NDP and no NAT.
# Pods therefore get real, world-routable addresses:
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
# The kubeadmCheck derivation below turns those three into a build-time check,
# so a nixpkgs bump that moves them fails the rebuild instead of the machine.
#
# What pods cannot reach
# ----------------------
# A pod has no IPv4 address, so an IPv4-only host is unreachable from inside
# the cluster -- github.com and ghcr.io among them. Image pulls are unaffected,
# because containerd runs on the host and the host is dual-stack. NAT64 and
# DNS64 are the answer to the rest, and they live in ./nat64.nix.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  kubernetes = pkgs.kubernetes;

  # See the allocation table in ./wireguard.nix. Keep the two in step.
  podSubnet = "2a01:4f9:3071:11d7:b0::/80";
  serviceSubnet = "fd00:10:96::/108";

  # eth0's address, named rather than discovered. kubelet has three global IPv6
  # addresses to choose between on this host (eth0, wg-dynhetz, the libvirt lab
  # bridge) and picks by a rule nothing here controls.
  nodeIP = "2a01:4f9:3071:11d7::2";

  # The first address of the pod subnet. The bridge plugin gives it to cni0 and
  # hands each pod a default route through it.
  podGateway = "2a01:4f9:3071:11d7:b0::1";

  # The WireGuard peer address from ./wireguard.nix, which is where kubectl runs
  # from when it is not running on dynhetz itself.
  wgAddress = "2a01:4f9:3071:11d7:90::1";

  criSocket = "unix:///run/containerd/containerd.sock";

  # The marker the kubeadm unit writes after `kubeadm init` returns 0, and the
  # one file kube-nuke below has to remove to make the next start provision
  # instead of skip. Named once, because two copies of a path are two things to
  # keep in step and nothing would report the day they stopped matching.
  initSentinel = "/var/lib/kubernetes/kubeadm-init-done";

  # containerd builds a pod sandbox without consulting the runtime spec, so this
  # image is the one thing it pulls on its own. Its version tracks containerd
  # releases by default and has to track kubeadm's instead: the two agree today,
  # and the day they stop, every sandbox fails to start over an image nothing in
  # this file mentions. kubeadmCheck below asserts the two still match.
  sandboxImage = "registry.k8s.io/pause:3.10.2";

  json = pkgs.formats.json { };

  # kubeadm takes extraArgs and extraVolumes as lists of records from v1beta4 on.
  args = lib.mapAttrsToList (name: value: { inherit name value; });

  # The host mounts the control plane needs to read a certificate.
  #
  # kubeadm already mounts /etc/ssl/certs into kube-apiserver and
  # kube-controller-manager. On NixOS that directory holds symlinks and nothing
  # else, and the chain runs two hops out of it:
  #
  #   /etc/ssl/certs/ca-certificates.crt
  #     -> /etc/static/ssl/certs/ca-certificates.crt
  #       -> /nix/store/...-nss-cacert-*/etc/ssl/certs/ca-bundle.crt
  #
  # Both hops have to exist inside the container or the bundle is a dangling
  # link, and every outbound TLS dial the control plane makes -- an admission
  # webhook, an OIDC issuer, an aggregated API server -- fails with no usable
  # trust store. Mounting the two paths is enough; /etc/static is a symlink to a
  # store path but a hostPath resolves it, and its own path string is stable
  # across generations.
  #
  # The alternative is to copy the real bundle over /etc/ssl/certs at activation
  # time, which is what an earlier attempt at this did. That works, and it also
  # means the file the whole host trusts is no longer the one Nix built.
  certVolumes = [
    {
      name = "nix-store";
      hostPath = "/nix/store";
      mountPath = "/nix/store";
      readOnly = true;
      pathType = "Directory";
    }
    {
      name = "etc-static";
      hostPath = "/etc/static";
      mountPath = "/etc/static";
      readOnly = true;
      pathType = "Directory";
    }
  ];

  clusterConfiguration = {
    apiVersion = "kubeadm.k8s.io/v1beta4";
    kind = "ClusterConfiguration";
    # Pinned to the package. Left unset, kubeadm asks dl.k8s.io what "stable"
    # means, and then the cluster's version depends on the day it was built.
    kubernetesVersion = "v${kubernetes.version}";
    networking = {
      inherit podSubnet serviceSubnet;
      dnsDomain = "cluster.local";
    };
    apiServer = {
      # kube-apiserver's --bind-address defaults to 0.0.0.0, which it documents
      # as "unspecified" and treats as every interface and both families -- so
      # an IPv6-only cluster needs nothing set here. Checked in `--help`, not
      # assumed: read as a literal IPv4 wildcard it would bind v4 only, and the
      # liveness probe kubeadm writes dials the v6 node address.
      certSANs = [
        nodeIP
        wgAddress
        "dynhetz"
        "localhost"
        "::1"
      ];
      extraVolumes = certVolumes;
    };
    controllerManager = {
      extraArgs = args { node-cidr-mask-size-ipv6 = "80"; };
      extraVolumes = certVolumes;
    };
    # kube-scheduler talks to nothing outside the cluster and kubeadm mounts no
    # certificate directory into it, so it gets neither volume.
    etcd.local.dataDir = "/var/lib/etcd";
  };

  initConfiguration = {
    apiVersion = "kubeadm.k8s.io/v1beta4";
    kind = "InitConfiguration";
    localAPIEndpoint = {
      advertiseAddress = nodeIP;
      bindPort = 6443;
    };
    nodeRegistration = {
      name = config.networking.hostName;
      inherit criSocket;
      # An empty list, said explicitly, removes the control-plane NoSchedule
      # taint kubeadm would otherwise add. There is no second node for a
      # workload to land on.
      taints = [ ];
      kubeletExtraArgs = args { node-ip = nodeIP; };
    };
    # How long kubeadm waits on the two things that can hang, cut from the
    # 4m0s each that it defaults to.
    #
    # This machine reaches "control-plane has initialized successfully" ten
    # seconds after `kubeadm init` starts, reset included, once the images are
    # local. The wait-control-plane phase is at most five of those. 90s is
    # eighteen times the observed time, so it fails only when something is
    # actually wrong.
    #
    # These are the numbers that matter, not the unit's TimeoutStartSec below.
    # A wait that kubeadm ends prints which component never answered. A wait
    # that systemd ends is SIGKILL and an empty journal. So kubeadm's limit
    # has to be the one that fires, and the unit's has to sit above it.
    #
    # Only these two are on the init path. discovery and tlsBootstrap belong to
    # `kubeadm join`, upgradeManifests to `kubeadm upgrade`, and no node here
    # ever runs either.
    timeouts = {
      controlPlaneComponentHealthCheck = "90s";
      kubeletHealthCheck = "90s";
    };
  };

  kubeletConfiguration = {
    apiVersion = "kubelet.config.k8s.io/v1beta1";
    kind = "KubeletConfiguration";
    cgroupDriver = "systemd";
    # dynhetz has 96 GiB of swap across both NVMe drives (../dynhetz/disko.nix).
    # kubelet refuses to start on a machine with swap unless told otherwise.
    # This only permits it; the default swapBehavior still gives containers
    # none of it.
    failSwapOn = false;
    # Not /etc/resolv.conf. networkd here means that is resolved's stub file
    # naming 127.0.0.53, and inside a pod's own network namespace that address
    # is the pod. CoreDNS would forward to itself and its loop detector would
    # shoot it. ../dynhetz/kubernetes.nix writes the file below instead.
    resolvConf = "/etc/kubernetes/resolv.conf";
  };

  kubeproxyConfiguration = {
    apiVersion = "kubeproxy.config.k8s.io/v1alpha1";
    kind = "KubeProxyConfiguration";
  };

  # kubeadm reads one file and splits it on ---, so the four documents arrive
  # concatenated rather than as four --config arguments.
  #
  # Not built out of pkgs.formats.yaml, which was the obvious way and does not
  # work. That writer puts a `%YAML 1.1` directive above its own `---` in every
  # file it generates, and kubeadm splits the stream on `---` textually before
  # handing each piece to a YAML parser -- so every document after the first
  # arrives starting with a directive and no document marker, and kubeadm fails
  # with `did not find expected <document start>`. Putting an extra `---` in
  # front instead makes the first document empty, which fails differently:
  # `kind and apiVersion is mandatory information that must be specified`.
  # Neither message names a file or a line.
  #
  # JSON is valid YAML and carries no directive, so the documents are joined as
  # JSON and yq reformats the result into something a person can read.
  kubeadmConfig =
    pkgs.runCommand "kubeadm-config.yaml"
      {
        nativeBuildInputs = [ pkgs.yq-go ];
        value = lib.concatMapStringsSep "\n---\n" builtins.toJSON [
          clusterConfiguration
          initConfiguration
          kubeletConfiguration
          kubeproxyConfiguration
        ];
        passAsFile = [ "value" ];
      }
      ''
        yq --prettyPrint --no-colors < "$valuePath" > $out
      '';

  # The pod network, written from Nix rather than after the fact.
  #
  # A multi-node cluster cannot do this: kube-controller-manager carves a subnet
  # per node out of the pod subnet, and no node knows its own until the cluster
  # exists. Here there is one node and it gets the whole /80, so the value is
  # known at eval time and the conflist can be a plain file.
  #
  # isDefaultGateway implies isGateway and makes the bridge plugin add the pod's
  # default route itself, through the gateway it derives from the range. Naming
  # ::/0 in ipam.routes as well -- which most published conflists do -- adds it
  # twice: the plugin only recognises an existing default route as its own if
  # that route names a gateway, and an ipam route does not, so the second
  # netlink add returns EEXIST and no pod ever gets a sandbox.
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
          ranges = [ [ { subnet = podSubnet; } ] ];
        };
      }
      {
        type = "portmap";
        capabilities.portMappings = true;
      }
    ];
  };
  # Throw this node's cluster away and provision a new one.
  #
  # The kubeadm unit below already knows how to reset a half-finished attempt,
  # so this is not a second copy of that logic: it removes the sentinel and the
  # state the unit's own tests read, then starts the unit and lets it do the
  # work. That way one script describes provisioning and this one only
  # describes forgetting.
  #
  # Three things `kubeadm reset` leaves behind, and each is a real failure
  # rather than untidiness:
  #
  #   the CNI bridge and its leases  host-local records every address it hands
  #                                  out. A lease that survives is an address
  #                                  the plugin believes is taken, so a rebuilt
  #                                  cluster starts on a smaller pool every
  #                                  time.
  #   kube-proxy's iptables chains   reset prints that it will not touch them.
  #   /var/lib/etcd's nodatacow      chattr +C only takes on an empty
  #                                  directory, and the activation script that
  #                                  normally sets it runs at switch time, not
  #                                  here. Leaving the directory in place is
  #                                  how the attribute gets lost for good, and
  #                                  nothing afterwards reports that etcd is
  #                                  now writing copy-on-write.
  #
  # ~/.kube/config needs nothing: `kubeadm init` writes a new CA and a new
  # admin.conf, and a symlink to that path follows it. A copy would not.
  kube-nuke = pkgs.writeShellApplication {
    name = "kube-nuke";
    runtimeInputs = with pkgs; [
      kubernetes
      systemd
      coreutils
      e2fsprogs
      iproute2
      iptables
      util-linux
      ethtool
      socat
      conntrack-tools
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

      # Tolerated: a reset that fails leaves state behind, and the kubeadm unit
      # tests for exactly that state and resets again before it inits.
      kubeadm reset --force --cri-socket ${criSocket} || true

      rm -f ${initSentinel}

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

  # The three things above that fail at `kubeadm init` rather than at eval,
  # turned into something a rebuild has to get past.
  #
  # kubeadm's own validator is the authority on its config, and it is versioned:
  # a nixpkgs bump that retires v1beta4, moves the service-CIDR limit, or
  # changes which argument the node mask is read from shows up here in seconds
  # rather than as a half-provisioned machine. The pause image is checked the
  # same way, against the list kubeadm would pull.
  #
  # Neither command needs a network or a cluster.
  kubeadmCheck =
    pkgs.runCommand "kubeadm-config-checked"
      {
        nativeBuildInputs = [ kubernetes ];
      }
      ''
        kubeadm config validate --config ${kubeadmConfig}

        want=${lib.escapeShellArg sandboxImage}
        got=$(kubeadm config images list --kubernetes-version v${kubernetes.version} \
                | grep '/pause:')
        if [ "$got" != "$want" ]; then
          echo "containerd's pinned sandbox image is $want" >&2
          echo "kubeadm ${kubernetes.version} wants $got" >&2
          exit 1
        fi

        ln -s ${kubeadmConfig} $out
      '';
in
{
  config = {
    # Building the system builds the check. extraDependencies lands in the
    # closure, so there is no way to switch onto a configuration kubeadm would
    # have rejected.
    system.extraDependencies = [ kubeadmCheck ];

    # ── the container runtime ────────────────────────────────────────────

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
        plugins."io.containerd.cri.v1.images".pinned_images.sandbox = sandboxImage;
      };
    };

    # ── the node ─────────────────────────────────────────────────────────

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
      # ./libvirt-lab-net.nix, which explains why "default" matters as much as
      # "all" for an interface created after boot. cni0 is exactly that case.
      # Repeated here rather than depended on: this file must stand on its own
      # the day the libvirt lab goes away. mkDefault because a sysctl is a
      # unique option and two plain definitions of the same value are still a
      # conflict -- so that file keeps the definition while it exists, and this
      # one takes over when it does not.
      "net.ipv6.conf.all.forwarding" = lib.mkDefault 1;
      "net.ipv6.conf.default.forwarding" = lib.mkDefault 1;
      # Nothing in this cluster carries IPv4, but kubeadm's preflight reads
      # /proc/sys/net/ipv4/ip_forward and refuses to run when it is 0. It is 1
      # on this host today only because libvirt set it imperatively at some
      # point, which is not a thing to depend on -- ./libvirt-lab-net.nix's
      # network is on its way out.
      "net.ipv4.ip_forward" = lib.mkDefault 1;
      # Go runtimes reserve far more address space than they touch.
      "vm.overcommit_memory" = 1;
    };

    environment.etc = {
      "cni/net.d/10-dynhetz.conflist".source = cniConfig;

      # What every pod gets as its /etc/resolv.conf, and what CoreDNS forwards
      # to. Hetzner's own resolvers, IPv6 only: a pod has no IPv4 address, so
      # the 185.12.64.x pair in ../dynhetz/default.nix would be a timeout here
      # rather than a fallback.
      # mkDefault, for the same reason the forwarding sysctls above use it:
      # ./nat64.nix replaces these resolvers with a DNS64 in front of them, and
      # two plain definitions of one option are a conflict rather than an
      # override. This file keeps the definition the day that one goes away.
      "kubernetes/resolv.conf".text = lib.mkDefault ''
        nameserver 2a01:4ff:ff00::add:1
        nameserver 2a01:4ff:ff00::add:2
      '';

      "crictl.yaml".text = ''
        runtime-endpoint: ${criSocket}
        image-endpoint: ${criSocket}
        timeout: 60
      '';
    };

    environment.systemPackages = [
      kubernetes
      kube-nuke
      pkgs.cri-tools
      pkgs.cni-plugins
      pkgs.etcd
    ];

    # kubectl with no arguments, for whoever is on the machine. The file is
    # cluster-admin credentials and the kubeadm unit below gives it to the wheel
    # group, which on this host is one person.
    environment.variables.KUBECONFIG = "/etc/kubernetes/admin.conf";

    # ── the firewall ─────────────────────────────────────────────────────

    # cni0 is trusted, and this is the rule the cluster does not work without.
    # A pod reaching a ClusterIP is DNATed to the node address and arrives back
    # on cni0 as INPUT. CoreDNS talking to the API server is that path, and so
    # is every controller that will ever run here. Without this the node goes
    # Ready, every pod starts, and nothing inside the cluster can reach the API.
    networking.firewall.trustedInterfaces = [ "cni0" ];

    # 6443 over WireGuard and nowhere else. kubectl on dynhetz itself reaches
    # the API server over loopback, which the firewall always accepts, because
    # the advertised address is one of this host's own.
    networking.firewall.interfaces."wg-dynhetz".allowedTCPPorts = [ 6443 ];

    # ── provisioning ─────────────────────────────────────────────────────

    systemd.tmpfiles.rules = [
      "d /etc/kubernetes 0755 root root -"
      "d /etc/kubernetes/manifests 0755 root root -"
      "d /var/lib/kubelet 0755 root root -"
      # Holds the kubeadm unit's own sentinel. Deliberately not under
      # /var/lib/kubelet or /etc/kubernetes: `kubeadm reset` empties both, and a
      # marker a reset can erase is a marker that cannot survive the failure it
      # exists to describe.
      "d /var/lib/kubernetes 0755 root root -"
    ];

    # etcd measures a cluster in fsync latency, and copy-on-write is the wrong
    # answer for a file rewritten in place all day. / is btrfs here
    # (../dynhetz/disko.nix), so the directory gets the nodatacow attribute
    # before etcd puts anything in it. chattr +C only takes on an empty
    # directory, which is why this runs at activation rather than after the
    # fact.
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
    # and the one that gates kubelet below -- lands in the kubelet-start phase,
    # which is roughly half way. An init that dies after that point leaves a
    # machine that looks provisioned and has no bootstrap token, no uploaded
    # config, no CoreDNS and no kube-proxy, and the next boot skips straight
    # past it. That is the worst state available, so nothing here treats a
    # kubeadm file as proof of anything.
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
    # Changing ${"$"}{kubeadmConfig} still does not re-provision anything. It
    # changes what a future init would do.
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
      # Nothing is needed in its place. kubelet's ConditionPathExists below is
      # the whole of the ordering, and kubeadm starts kubelet itself.
      path = with pkgs; [
        kubernetes
        util-linux
        iproute2
        iptables
        ethtool
        socat
        conntrack-tools
        coreutils
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # A backstop, and only a backstop. The init path's own limits are
        # `timeouts` in the InitConfiguration above, and they are what should
        # end a bad run, because kubeadm says what it was waiting for and
        # systemd does not.
        #
        # So this covers the one part those limits do not: pulling the control
        # plane images. That happens in preflight, before any wait kubeadm
        # bounds, and it took 19s here on a cold store. Five minutes leaves
        # room for a slow pull on top of a 90s health check.
        TimeoutStartSec = "5min";
      };
      script = ''
        set -euo pipefail

        sentinel=${initSentinel}

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
            kubeadm reset --force --cri-socket ${criSocket}
          fi

          kubeadm init --config ${kubeadmConfig} --skip-token-print
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

    # kubelet reads /var/lib/kubelet/config.yaml and kubeadm-flags.env, and
    # kubeadm is what writes both. ConditionPathExists is how the unit says so:
    # before provisioning it is skipped, which systemd reports as inactive
    # rather than failed. Started too early it crash-loops instead, and that
    # reads as a broken node rather than an unprovisioned one.
    systemd.services.kubelet = {
      description = "kubelet: the Kubernetes node agent";
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
        KUBELET_CONFIG_ARGS = "--config=/var/lib/kubelet/config.yaml";
      };
      serviceConfig = {
        # Written by kubeadm, so absent until it has run -- hence the leading
        # dash. It carries --container-runtime-endpoint and the node's pod
        # infra image, which is why kubelet cannot simply be given flags here.
        EnvironmentFile = [ "-/var/lib/kubelet/kubeadm-flags.env" ];
        ExecStart =
          "${lib.getExe' kubernetes "kubelet"} $KUBELET_KUBECONFIG_ARGS"
          + " $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS";
        Restart = "always";
        RestartSec = 5;
        LimitNOFILE = 1048576;
        TasksMax = "infinity";
      };
    };
  };
}
