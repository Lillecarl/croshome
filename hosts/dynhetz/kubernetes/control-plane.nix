# What the cluster is configured to be.
#
# Four kubeadm documents and a check over them. Nothing here starts anything:
# ./provision.nix is what hands the result to `kubeadm init`. Splitting the two
# means the description of a cluster can be read without reading the machinery
# that builds one.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dynhetz.kubernetes;
  kubernetes = cfg.package;

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
      podSubnet = cfg.podSubnet;
      serviceSubnet = cfg.serviceSubnet;
      dnsDomain = "cluster.local";
    };
    apiServer = {
      # kube-apiserver's --bind-address defaults to 0.0.0.0, which it documents
      # as "unspecified" and treats as every interface and both families -- so
      # an IPv6-only cluster needs nothing set here. Checked in `--help`, not
      # assumed: read as a literal IPv4 wildcard it would bind v4 only, and the
      # liveness probe kubeadm writes dials the v6 node address.
      certSANs = [
        cfg.nodeIP
        cfg.wgAddress
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
      advertiseAddress = cfg.nodeIP;
      bindPort = 6443;
    };
    nodeRegistration = {
      name = config.networking.hostName;
      criSocket = cfg.criSocket;
      # An empty list, said explicitly, removes the control-plane NoSchedule
      # taint kubeadm would otherwise add. There is no second node for a
      # workload to land on.
      taints = [ ];
      kubeletExtraArgs = args { node-ip = cfg.nodeIP; };
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
    # These are the numbers that matter, not the TimeoutStartSec on
    # kubeadm.service in ./provision.nix. A wait that kubeadm ends prints which
    # component never answered. A wait that systemd ends is SIGKILL and an
    # empty journal. So kubeadm's limit has to be the one that fires, and the
    # unit's has to sit above it.
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
    # dynhetz has 96 GiB of swap across both NVMe drives (../disko.nix).
    # kubelet refuses to start on a machine with swap unless told otherwise.
    # This only permits it; the default swapBehavior still gives containers
    # none of it.
    failSwapOn = false;
    # Not /etc/resolv.conf. networkd here means that is resolved's stub file
    # naming 127.0.0.53, and inside a pod's own network namespace that address
    # is the pod. CoreDNS would forward to itself and its loop detector would
    # shoot it. ./node.nix writes the file below instead.
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

  # The constraints in ./default.nix's header that fail at `kubeadm init`
  # rather than at eval, turned into something a rebuild has to get past.
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

        want=${lib.escapeShellArg cfg.sandboxImage}
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
    dynhetz.kubernetes.kubeadmConfig = kubeadmConfig;

    # Building the system builds the check. extraDependencies lands in the
    # closure, so there is no way to switch onto a configuration kubeadm would
    # have rejected.
    system.extraDependencies = [ kubeadmCheck ];
  };
}
