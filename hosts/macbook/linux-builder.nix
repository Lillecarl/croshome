{
  lib,
  inputs,
  ...
}:
let
  # Not the pinned nixpkgs. Hydra builds darwin.linux-builder for the release
  # channels but not for unstable, and the VM is a NixOS system: taking it from
  # unstable leaves 21 aarch64-linux derivations -- system-path, etc, activate,
  # nixos-system -- that no cache has and that this Mac cannot build. That is
  # the bootstrap the builder is supposed to break, so it cannot depend on it.
  #
  # Nothing else in this configuration reads this package set, and the builder
  # is infrastructure rather than something to keep in step with the host.
  stable = import inputs.nixpkgs-stable { system = "aarch64-darwin"; };
in
{
  nix.linux-builder = {
    enable = true;
    package = stable.darwin.linux-builder;

    # mkForce because nixos/modules/profiles/nix-builder-vm.nix already sets
    # both, and a second definition without it is a conflict rather than an
    # override.
    #
    # The stock VM is one core and 3 GiB, which proves the mechanism and little
    # else. This machine has 15 cores and 24 GiB, so take half the memory and
    # about half the cores and leave the rest to the host. Changing these
    # rebuilds four derivations, all of them darwin ones, so it does not
    # reintroduce the bootstrap problem above -- but anything that changes the
    # *guest* closure does. Leave binfmt and extra packages until the builder
    # runs and can build its own next image.
    config = {
      virtualisation.cores = lib.mkForce 8;
      virtualisation.memorySize = lib.mkForce 8192; # MiB
    };
  };

  # The VM only offers aarch64-linux. hetztop is x86_64-linux, so this does not
  # verify that host yet; it covers ChromeOS and anything aarch64, and it is
  # what makes an IFD that needs Linux resolve at all.
}
