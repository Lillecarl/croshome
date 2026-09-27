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
# easykubenix comes out of the pinned umbrella's own source record, never from
# a fetch of its own. nixidae holds seven repositories and no submodules: each
# one resolves from its `nix/sources.lock`, and `sources` below is that record,
# read as a set of directories.
#
# Passing `sources` on is the part that matters. easykubenix defaults it to a
# lookup that fetches the *published* umbrella when it cannot see one beside
# it, and from a store path it never can -- so nanopynix and adios would come
# from a pin nothing here chose, beside the ones this configuration already
# builds.
#
# `system` is passed for a different reason: both files default it to
# `builtins.currentSystem`, which a pure evaluation cannot read.
{
  pkgs,
  inputs,
}:
let
  umbrella = import inputs.nixidae {
    inherit pkgs;
    inherit (pkgs.stdenv.hostPlatform) system;
  };
in
import umbrella.sources.easykubenix {
  inherit pkgs;
  inherit (umbrella) sources;
  inherit (pkgs.stdenv.hostPlatform) system;
  modules = [
    ./modules
    # nixkube's module tree, from the same umbrella. See ./modules/nixkube.nix.
    (umbrella.sources.nixkube + "/kubenix")
    { _module.args.sources = import (umbrella.sources.nixkube + "/nix/sources.nix"); }
  ];
}
