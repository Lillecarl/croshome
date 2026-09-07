# CDI: how a disk image becomes a volume KubeVirt can boot.
#
# ./kubevirt.nix runs a VM and ./topolvm.nix gives it a disk, and neither one
# puts anything on that disk. CDI closes that gap. A DataVolume names a source
# -- an HTTP URL, a container registry, an upload -- and CDI creates the
# PersistentVolumeClaim, runs a pod that writes the image into it, and converts
# the format on the way. A Talos disk image becomes a bootable root volume that
# way, which is the last piece this directory needed.
#
# The same shape as ./kubevirt.nix, for the same reasons: an operator from the
# release YAML, and a custom resource written here. Read that file for why the
# release YAML is fetched with a hash, why the objects the operator creates are
# not written here, and why one apply is enough.
#
# Versioned on its own. CDI is a separate project from KubeVirt with a separate
# release train, and KubeVirt 1.8 pins no CDI version -- its own test harness
# supplies one. So this tracks CDI's own latest rather than something derived
# from ./kubevirt.nix's version.
{ pkgs, ... }:
let
  version = "1.66.1";

  release =
    file: hash:
    pkgs.fetchurl {
      inherit hash;
      url = "https://github.com/kubevirt/containerized-data-importer/releases/download/v${version}/${file}";
    };
in
{
  importyaml.cdi-operator.src = release "cdi-operator.yaml" "sha256-x9kr0bLuGjlSpZkAAEN8CNWBCfMcC9SKthiOwnoT4iQ=";

  # The CDI object is cluster-scoped, so it goes under `none` rather than under
  # the cdi namespace its operator runs in.
  kubernetes.resources.none.CDI.cdi.spec = {
    imagePullPolicy = "IfNotPresent";

    # HonorWaitForFirstConsumer is upstream's own default in cdi-cr.yaml and it
    # matters more here than it does there. ./topolvm.nix's storage class is
    # WaitForFirstConsumer, because TopoLVM cannot create a logical volume
    # until it knows which node the pod lands on. Without this gate CDI binds
    # its claim immediately and takes that decision away from the scheduler.
    config.featureGates = [ "HonorWaitForFirstConsumer" ];

    # No nodeSelector, unlike cdi-cr.yaml, which pins both to
    # kubernetes.io/os: linux. There is one node, it is Linux, and it carries
    # no taint -- so the selector would only restate where everything already
    # goes.
  };

  # A StorageProfile is how CDI records what it may ask of a storage class. It
  # writes one per class on its own, and this overrides the one it wrote.
  #
  # Left alone, CDI reads its own detected profile for topolvm-provisioner,
  # finds Block listed ahead of Filesystem, and asks for a Block volume. Its
  # importer then crash-loops:
  #
  #   blockdev: cannot open /dev/cdi-block-volume: Permission denied
  #
  # The importer pod runs as UID 107 with runAsNonRoot, all capabilities
  # dropped, and no fsGroup at all. A block device kubelet maps into a pod is
  # root-owned, and nothing in that pod raises the privilege to open it.
  # TopoLVM's CSIDriver says fsGroupPolicy: ReadWriteOnceWithFSType, which
  # applies an fsGroup only to a volume that has a filesystem type -- so a
  # Block volume gets no ownership change from that side either.
  #
  # Naming Filesystem as the only claim property set makes CDI ask for a
  # volume it can write to. The cost is real and worth stating: the logical
  # volume then carries xfs and the VM's disk is a file on it, rather than the
  # VM writing to the logical volume directly.
  #
  # This object needs CDI already serving, unlike everything else here. Its
  # CRD is not in cdi-operator.yaml -- the running operator creates
  # storageprofiles.cdi.kubevirt.io -- so a first apply against a cluster with
  # no CDI fails on this one object and the apply after it succeeds. That is
  # the case ../modules/default.nix's header warns about, and this is the file
  # that has it.
  kubernetes.apiMappings.StorageProfile = "cdi.kubevirt.io/v1beta1";
  kubernetes.resources.none.StorageProfile.topolvm-provisioner.spec.claimPropertySets = [
    {
      accessModes = [ "ReadWriteOnce" ];
      volumeMode = "Filesystem";
    }
  ];
}
