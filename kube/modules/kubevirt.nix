# KubeVirt: the thing that actually runs a virtual machine.
#
# A VM becomes a pod. virt-launcher is the pod, qemu runs inside it, and the
# VM's disks and interfaces are the pod's volumes and interfaces -- which is
# what makes ./topolvm.nix and ./multus.nix useful to it rather than merely
# present. This is the component the whole directory exists to reach: a Talos
# node is a VM here.
#
# Two objects, and they are not the same kind of thing
# ---------------------------------------------------
# `virt-operator` is a Deployment, and the KubeVirt custom resource below is
# what it reconciles. The operator installs virt-api, virt-controller and
# virt-handler itself, from the CR, so those are not written here and must not
# be: they carry the operator's own version labels, and anything else applying
# them fights the operator for ownership.
#
# `--prune` does not touch them for the same reason it does not touch kubeadm's
# objects: they carry no `ekn.dev/discriminator` label, so they are outside the
# scope kluctl lists back.
#
# The release YAML, not a chart
# -----------------------------
# KubeVirt publishes one file per release and no Helm chart. `pkgs.fetchurl`
# with a hash makes it a store path, which `importyaml` takes directly -- and
# keeps the fetch pure. Passing the URL as a string instead would make
# `importyaml` call `builtins.fetchTree`, which has no hash and so cannot be
# evaluated without network access.
{ pkgs, ... }:
let
  version = "1.8.4";

  release =
    file: hash:
    pkgs.fetchurl {
      inherit hash;
      url = "https://github.com/kubevirt/kubevirt/releases/download/v${version}/${file}";
    };
in
{
  importyaml.kubevirt-operator.src = release "kubevirt-operator.yaml" "sha256-0dgmTuxbgCwSK+xsVNjDsR4RnuKlx1YCqqi1PqOFfto=";

  # The custom resource, written here rather than imported from the release's
  # own kubevirt-cr.yaml. That file is five empty fields, and every one of the
  # decisions below would be a patch over it.
  #
  # It applies in a later barrier than the CRD the operator YAML carries, which
  # `ekn` waits on to become Established. It does not need virt-operator to be
  # *running*: a KubeVirt object is stored by the API server like any other,
  # and the operator reconciles it whenever it starts. So one apply is enough,
  # and what says the install worked is the CR's Available condition, not the
  # apply.
  kubernetes.resources.kubevirt.KubeVirt.kubevirt.spec = {
    certificateRotateStrategy = { };
    customizeComponents = { };
    workloadUpdateStrategy = { };

    # Already in the node's image store after the first pull, and a VM's
    # workload pod is not a thing to make wait on a registry.
    imagePullPolicy = "IfNotPresent";

    # One node, so one of everything. virt-api and virt-controller are
    # two-replica deployments by default with an anti-affinity that keeps the
    # replicas apart, and there is no second node to keep them apart on -- so
    # the second replica of each stays Pending for as long as this cluster has
    # one node.
    infra.replicas = 1;

    configuration = { };
  };
}
