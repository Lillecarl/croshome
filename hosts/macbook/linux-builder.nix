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
    # Off: ../vz-builder does this job on Apple's hypervisor, only while a
    # build needs it, and for x86_64-linux as well. Everything below is left
    # intact rather than deleted, because this is the way back if that one
    # breaks.
    #
    # To revive it, flip this to true. If the VZ *guest* is what broke and
    # needs a config change, turn `nix.linux-vz-builder.enable` off in the same
    # edit: the guest is an aarch64-linux system, so building a changed one
    # needs a Linux builder, and that is the deadlock. With that off the
    # darwin system has no Linux derivation left to build, so it builds here,
    # and this VM's own image comes from the cache rather than being built --
    # which is the whole reason `package` below comes from nixpkgs-stable.
    enable = false;
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
