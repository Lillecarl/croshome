# Multus: a second network interface for a pod, and therefore for a VM.
#
# A Talos node needs to sit on a cluster network that is not the pod network.
# Kubernetes gives a pod exactly one interface, so something has to put the
# second one there. Multus is that something: it becomes the CNI plugin
# containerd calls, and it calls the real plugins -- the pod network for eth0,
# and whatever a NetworkAttachmentDefinition names for net1, net2 and so on.
#
# Thick, not thin
# ---------------
# Multus ships in two shapes. The thin one is a single binary on the node that
# talks to the API server itself, which means a kubeconfig with a service
# account token has to exist on disk before any pod starts. Nothing here can
# write that file: it holds a credential the cluster mints at runtime, and Nix
# builds are the wrong place for those.
#
# The thick one splits in two. `multus-shim` is the binary containerd calls and
# it holds no credentials at all -- it opens a unix socket to `multus-daemon`
# and hands the request over. The daemon is the DaemonSet below, so it reaches
# the API with an ordinary ServiceAccount, the way every other controller does.
#
# What is on the node instead, and why
# ------------------------------------
# Two things, both in ../../hosts/dynhetz/kubernetes/runtime.nix:
#
#   the multus-shim binary   as a store path in containerd's cni.bin_dirs.
#   /etc/cni/net.d/00-multus.conf   the configuration containerd reads.
#
# Upstream's DaemonSet installs both itself: an init container copies the shim
# into /host/opt/cni/bin, and the daemon generates the conf file. Neither works
# here. There is no /opt/cni/bin on this node, and a file the daemon writes
# outlives the daemon -- removing this module leaves a 00-multus.conf naming a
# socket nothing serves, and then no pod on the node can start. A file Nix owns
# disappears on the next switch.
#
# So this module drops the init container, and tells the daemon not to generate
# anything. See `multusConfigFile` below for how that is said.
#
# Applying this
# -------------
# Apply this before the rebuild that puts 00-multus.conf on the node, not
# after. The DaemonSet is hostNetwork, so it starts with no CNI at all; the
# node keeps using the pod network directly until the file appears, and by then
# the daemon is already answering. The other order leaves a window where
# containerd calls a shim that has nobody to talk to, and every new pod fails.
{ pkgs, ... }:
let
  # The same file ../../hosts/dynhetz/kubernetes/runtime.nix reads. That is the
  # point of it: the delegate the daemon runs and the fallback conf on the node
  # are one value, so they cannot drift.
  network = import ../../hosts/dynhetz/kubernetes/network.nix;

  version = "4.0.2";

  # Matched to pkgs.multus-cni, which is where the shim on the node comes from.
  # The shim and the daemon speak a versioned API over that socket, so these
  # two are one version or they are a bug.
  image = "ghcr.io/k8snetworkplumbingwg/multus-cni:v${version}-thick";

  labels = {
    app = "multus";
    name = "multus";
    tier = "node";
  };

  # What the daemon does when the shim calls it.
  #
  # `clusterNetwork` is the default network -- what a pod gets as eth0 when its
  # annotation asks for nothing else. A value with no "/" in it is looked up
  # first as a NetworkAttachmentDefinition in the multus namespace, which
  # defaults to kube-system, and that is the object at the bottom of this file.
  #
  # A name and not a path, deliberately. The obvious path is
  # /host/etc/cni/net.d/10-dynhetz.conflist, and it does not work: that file is
  # a symlink into /etc/static and then into /nix/store, and neither is mounted
  # in this pod, so the daemon would follow it to nowhere. Reading the same
  # bytes from the API server avoids the question.
  #
  # `chrootDir` is what makes the delegate runnable at all. The daemon executes
  # the bridge and portmap binaries itself, from inside this pod, and they need
  # the node's own /run, /var/lib/cni and network namespaces. Chrooting into
  # the hostPath mount of / gives them a node's view. It also means the store
  # paths in containerd's CNI_PATH -- which the shim forwards -- resolve.
  #
  # `multusConfigFile` is how "generate nothing" is said. Anything other than
  # the string "auto" turns the generator off; what the daemon does with the
  # value instead is copy that one file into `cniConfigDir`. Nix already placed
  # the real one on the node, so the copy has nothing useful to do, and
  # /tmp is where it is sent to do it.
  #
  # `binDir` is not optional, and the reason is measured rather than assumed.
  # multus builds the search path as its own `binDir` followed by whatever
  # CNI_PATH holds -- and the shim does not forward CNI_PATH, so containerd's
  # cni.bin_dirs never reaches the daemon. Without this line the daemon looks
  # in /opt/cni/bin, which this node does not have, and every pod fails with
  # `failed to find plugin "bridge" in path [/opt/cni/bin]`.
  #
  # A store path, which works because of `chrootDir`: the delegate runs in the
  # node's own root, where /nix/store is real. It is the same derivation
  # ../../hosts/dynhetz/kubernetes/runtime.nix puts in cni.bin_dirs -- one
  # nixpkgs pin and one overlay produce one path -- so the plugins the daemon
  # runs are the plugins the node has.
  daemonConfig = {
    binDir = "${pkgs.cni-plugins}/bin";
    chrootDir = "/hostroot";
    confDir = "/host/etc/cni/net.d";
    cniDir = "/var/lib/cni/multus";
    socketDir = "/host/run/multus/";
    cniVersion = network.multusShim.cniVersion;
    logLevel = "verbose";
    logToStderr = true;
    clusterNetwork = network.pod.name;
    multusConfigFile = "/etc/cni/net.d/multus.d/00-multus.conf";
    cniConfigDir = "/tmp";
  };

  hostPathVolume = name: path: {
    inherit name;
    hostPath = { inherit path; };
  };
in
{
  # A NetworkAttachmentDefinition is a custom resource, so nothing in
  # easykubenix's generated api mapping knows its group. The CRD below is
  # declared through `kubernetes.crds`, which takes complete objects and
  # derives no mapping from them.
  kubernetes.apiMappings.NetworkAttachmentDefinition = "k8s.cni.cncf.io/v1";

  # Transcribed from upstream's deployments/multus-daemonset-thick.yml at
  # v4.0.2. `kubernetes.crds` and not `kubernetes.resources`: a CRD's OpenAPI
  # schema is the worst case for the per-leaf type check that option tree runs,
  # and this one is already a complete object.
  kubernetes.crds = [
    {
      apiVersion = "apiextensions.k8s.io/v1";
      kind = "CustomResourceDefinition";
      metadata.name = "network-attachment-definitions.k8s.cni.cncf.io";
      spec = {
        group = "k8s.cni.cncf.io";
        scope = "Namespaced";
        names = {
          plural = "network-attachment-definitions";
          singular = "network-attachment-definition";
          kind = "NetworkAttachmentDefinition";
          shortNames = [ "net-attach-def" ];
        };
        versions = [
          {
            name = "v1";
            served = true;
            storage = true;
            schema.openAPIV3Schema = {
              description = "NetworkAttachmentDefinition is a CRD schema specified by the Network Plumbing Working Group to express the intent for attaching pods to one or more logical or physical networks.";
              type = "object";
              properties = {
                apiVersion.type = "string";
                kind.type = "string";
                metadata.type = "object";
                spec = {
                  description = "NetworkAttachmentDefinition spec defines the desired state of a network attachment";
                  type = "object";
                  properties.config = {
                    description = "NetworkAttachmentDefinition config is a JSON-formatted CNI configuration";
                    type = "string";
                  };
                };
              };
            };
          }
        ];
      };
    }
  ];

  kubernetes.resources = {
    none.ClusterRole.multus.rules = [
      {
        apiGroups = [ "k8s.cni.cncf.io" ];
        resources = [ "*" ];
        verbs = [ "*" ];
      }
      {
        apiGroups = [ "" ];
        resources = [
          "pods"
          "pods/status"
        ];
        verbs = [
          "get"
          "update"
        ];
      }
      {
        apiGroups = [
          ""
          "events.k8s.io"
        ];
        resources = [ "events" ];
        verbs = [
          "create"
          "patch"
          "update"
        ];
      }
    ];

    none.ClusterRoleBinding.multus = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "multus";
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = "multus";
          namespace = "kube-system";
        }
      ];
    };

    kube-system = {
      ServiceAccount.multus = { };

      ConfigMap.multus-daemon-config = {
        metadata.labels = labels;
        data = {
          # The daemon reads this from its default path,
          # /etc/cni/net.d/multus.d/daemon-config.json, which is where the
          # volume below mounts the whole ConfigMap.
          "daemon-config.json" = builtins.toJSON daemonConfig;
          # The second key exists only to give `multusConfigFile` above
          # something real to point at. It is the same value Nix writes to the
          # node, so the copy the daemon makes into /tmp is a copy of the file
          # that is already in the right place.
          "00-multus.conf" = builtins.toJSON network.multusShim;
        };
      };

      DaemonSet.kube-multus-ds = {
        metadata.labels = labels;
        spec = {
          selector.matchLabels.name = "multus";
          updateStrategy.type = "RollingUpdate";
          template = {
            metadata.labels = labels;
            spec = {
              # Both are what lets this pod start before the network it
              # provides exists, and reach the namespaces it has to enter.
              hostNetwork = true;
              hostPID = true;
              serviceAccountName = "multus";
              terminationGracePeriodSeconds = 10;
              tolerations = [
                {
                  operator = "Exists";
                  effect = "NoSchedule";
                }
                {
                  operator = "Exists";
                  effect = "NoExecute";
                }
              ];
              containers = [
                {
                  name = "kube-multus";
                  inherit image;
                  command = [ "/usr/src/multus-cni/bin/multus-daemon" ];
                  securityContext.privileged = true;
                  resources = {
                    requests = {
                      cpu = "100m";
                      memory = "50Mi";
                    };
                    limits = {
                      cpu = "100m";
                      memory = "50Mi";
                    };
                  };
                  volumeMounts = [
                    {
                      name = "cni";
                      mountPath = "/host/etc/cni/net.d";
                    }
                    {
                      name = "host-run";
                      mountPath = "/host/run";
                    }
                    {
                      name = "host-var-lib-cni-multus";
                      mountPath = "/var/lib/cni/multus";
                    }
                    {
                      name = "host-var-lib-kubelet";
                      mountPath = "/var/lib/kubelet";
                    }
                    {
                      name = "host-run-k8s-cni-cncf-io";
                      mountPath = "/run/k8s.cni.cncf.io";
                    }
                    {
                      name = "host-run-netns";
                      mountPath = "/run/netns";
                      mountPropagation = "HostToContainer";
                    }
                    {
                      name = "multus-daemon-config";
                      mountPath = "/etc/cni/net.d/multus.d";
                      readOnly = true;
                    }
                    {
                      name = "hostroot";
                      mountPath = "/hostroot";
                      mountPropagation = "HostToContainer";
                    }
                  ];
                }
              ];
              volumes = [
                (hostPathVolume "cni" "/etc/cni/net.d")
                (hostPathVolume "hostroot" "/")
                (hostPathVolume "host-run" "/run")
                (hostPathVolume "host-var-lib-cni-multus" "/var/lib/cni/multus")
                (hostPathVolume "host-var-lib-kubelet" "/var/lib/kubelet")
                (hostPathVolume "host-run-k8s-cni-cncf-io" "/run/k8s.cni.cncf.io")
                (hostPathVolume "host-run-netns" "/run/netns")
                {
                  name = "multus-daemon-config";
                  configMap.name = "multus-daemon-config";
                }
              ];
            };
          };
        };
      };

      # The default network, as an object the daemon can read over the API.
      # Its name is what `clusterNetwork` above names, and its config is the
      # same value ../../hosts/dynhetz/kubernetes/runtime.nix writes to
      # /etc/cni/net.d/10-dynhetz.conflist.
      #
      # `spec.config` is a string in this CRD -- a CNI configuration carried
      # inside a Kubernetes object rather than expressed as one -- so it is
      # JSON encoded here rather than nested.
      NetworkAttachmentDefinition.${network.pod.name}.spec.config = builtins.toJSON network.pod;
    };
  };
}
