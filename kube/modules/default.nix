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
  imports = [
    ./namespaces.nix
    ./multus.nix
    ./kubevirt.nix
  ];
}
