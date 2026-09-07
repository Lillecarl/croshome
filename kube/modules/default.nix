# What dynhetz's cluster runs, on top of the node ../../hosts/dynhetz/kubernetes
# provisions.
#
# The goal these four serve is Talos clusters as virtual machines on this host,
# replacing the libvirt lab in ../../hosts/dynhetz/libvirt-lab-net.nix. Each
# one is a piece of that:
#
#   multus.nix    a second network interface for a VM, so a Talos node can sit
#                 on a cluster network that is not the pod network.
#   topolvm.nix   disks for those VMs, carved out of this host's LVM thin pool
#                 rather than out of a file on the root filesystem.
#   kubevirt.nix  the thing that actually runs a VM.
#   cdi.nix       how a Talos image becomes a disk KubeVirt can boot.
#
# Order matters when they are applied, and easykubenix already knows most of
# it: namespaces and CRDs go down first, custom resources last. What it cannot
# know is that a KubeVirt or CDI custom resource wants its operator *serving*,
# not merely installed. Each file says how it handles that.
{
  # The prune scope, named rather than left to the default.
  #
  # `--prune` deletes every object carrying this label that the current apply
  # did not produce, so it is not a cosmetic name: it is the list of things one
  # apply is allowed to delete. Twenty objects carry it here, including all
  # four operators below.
  #
  # The default is the string "easykubenix", which is what any other
  # easykubenix configuration also gets by default. Two of them against this
  # one cluster would each treat the other's objects as leftovers and delete
  # them -- and the deletions land on operators, not on something recoverable
  # by re-applying. A name of this repository's own means a second instance has
  # to collide deliberately rather than by sharing a default.
  ekn.discriminator = "croshome";

  imports = [
    ./namespaces.nix
    ./multus.nix
    ./kubevirt.nix
    ./topolvm.nix
    ./cdi.nix
  ];
}
