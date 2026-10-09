# nixkube mounts a Nix store into pods over CSI ephemeral volumes, so a
# workload here can run a store path this configuration builds, with no
# container image.
#
# The node substitutes from dynhetz's own store, which Harmonia serves
# (../../hosts/dynhetz/kubernetes/store-cache.nix). A closure built on
# this machine is therefore already available, and no in-cluster cache is
# needed: pynixd is off.
#
# Upstream's module tree is imported in ../default.nix, not here: an
# `imports` path cannot come from a module argument.
{
  nixkube = {
    enable = true;
    # dynhetz is the only node. Both keys: a definition replaces the
    # default set rather than merging into it.
    systems = {
      x86_64-linux = true;
      aarch64-linux = false;
    };

    pynixd.enable = false;

    # dynhetz's address on cni0.
    nixConfig.settings = {
      substituters = [ "http://[2a01:4f9:3071:11d7:b0::1]:5000" ];
      trusted-public-keys = [ "dynhetz-nix-serve-1:pa9YeYxSwmw43QxTBwicuCuyOzIzWMWi0n0X9eIwxJs=" ];
    };
  };
}
