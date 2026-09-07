# dynhetz's cluster, as manifests rather than as a machine.
#
# Deliberately not part of any NixOS configuration. Nothing here is imported
# by ../hosts/dynhetz, nothing lands in the system closure, and `ai-rebuild`
# does not touch the cluster. Applying is its own step:
#
#   nix run --file . cluster.deploymentScript -- --yes --prune
#   nix run --file . cluster.validationScript     # check against a throwaway apiserver
#   nix build --file . cluster.manifestYAMLFile   # just look at the YAML
#
# The deployment script hands everything after `--` to kluctl. With no flags it
# prints a diff and asks, which is the right default for a person and an EOF
# error for a script, so a non-interactive run needs `--yes`. `--prune` deletes
# what a previous apply left behind and this one no longer produces; it is safe
# beside kubeadm's own objects because kluctl only ever considers objects
# carrying the `easykubenix` discriminator it stamps.
#
# That split is the point. A cluster is state that outlives a generation and
# survives a rollback, so tying it to activation would mean every rebuild is
# also a deploy, and a rollback of the machine silently is not a rollback of
# the cluster. Keeping it apart also means ../hosts/dynhetz/kubernetes/kube-nuke.nix
# can throw the cluster away without the host configuration noticing.
#
# What is still in NixOS, and has to be
# -------------------------------------
# Only the parts that are not Kubernetes objects at all: a CNI binary on the
# node and the conflist that names it. Those are files on a disk that a kubelet
# reads before any of this exists. They live in
# ../hosts/dynhetz/kubernetes/runtime.nix.
#
# Portability
# -----------
# The modules under ./modules are easykubenix -- the NixOS module system
# producing Kubernetes objects. What comes out is plain YAML, so the escape
# hatch from this tool to any other is `nix build --file . cluster.manifestYAMLFile`
# and a `kubectl apply -f` of the result. Nothing here is stored only inside a
# tool's own database.
#
# easykubenix comes from inside the pinned umbrella rather than from a fetch of
# its own. Its default.nix looks for `../nix/wire.nix` first and only fetches an
# umbrella when it cannot see one, so importing it here -- where the umbrella is
# the checkout above it -- resolves nanopynix and adios from the same pin. See
# ../flake.nix for why that input is a git fetch with submodules.
{
  pkgs,
  inputs,
}:
import "${inputs.nixidae}/easykubenix" {
  inherit pkgs;
  modules = [ ./modules ];
}
