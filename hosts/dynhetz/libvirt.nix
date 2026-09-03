# Lets lillecarl (added to the libvirtd group in ./default.nix) create and
# manage VMs on this machine -- either locally with virsh (pulled in
# automatically by virtualisation.libvirtd.enable) or remotely, e.g.
# `virt-manager` on another machine pointed at qemu+ssh://lillecarl@dynhetz/system.
{ pkgs, ... }:
{
  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      # dynhetz only ever runs x86_64-linux guests on x86_64-linux
      # hardware -- qemu_kvm skips the cross-architecture emulators the
      # plain qemu package would otherwise build and ship.
      package = pkgs.qemu_kvm;
      # Emulated TPM 2.0, off by default -- needed for guests that require
      # one (Windows 11, most notably). UEFI/OVMF firmware needs no
      # equivalent option any more: all the firmware images QEMU itself
      # ships are available automatically.
      swtpm.enable = true;
    };
  };
}
