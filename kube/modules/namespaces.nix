# The namespaces the operators live in.
#
# Stated here rather than left to each upstream manifest, because that is what
# makes the first apply of any of them work. easykubenix orders a Namespace
# ahead of everything that goes in one, so a namespace this file owns exists
# before the operator's own objects reference it -- an upstream bundle that
# carries its own Namespace object gets the same result, and one that does not
# would otherwise fail its first apply and pass its second.
#
# The names are upstream's own defaults, not a choice. Every one of these
# operators has RBAC, webhook configurations and controller flags that name its
# namespace, so moving one means patching objects that arrive as a bundle.
{
  kubernetes.resources.none.Namespace = {
    kubevirt = { };
    cdi = { };
    topolvm-system = { };
    # Multus is a DaemonSet, not an operator, and upstream puts it in
    # kube-system. It stays there: its ClusterRoleBinding names that
    # ServiceAccount, and kubeadm already owns the namespace, so nothing here
    # creates it.
  };
}
