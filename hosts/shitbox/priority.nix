# The desktop stays responsive while the machine builds. Weights, which only
# matter when the CPU is contended, and compare siblings in the cgroup tree.
{ pkgs, ... }:
{
  # Against system.slice, where nix-daemon is: idle weight there alone would
  # still give the slice half the CPU.
  systemd.slices.user.sliceConfig = {
    CPUWeight = 10000;
    IOWeight = 1000;
  };
  systemd.services.nix-daemon.serviceConfig = {
    CPUWeight = "idle";
    IOWeight = 10;
  };

  # The login session's scope holds domicile's processes and no more: its apps
  # have scopes of their own under user@.service.
  systemd.packages = [
    (pkgs.writeTextDir "lib/systemd/system/session-.scope.d/50-priority.conf" ''
      [Scope]
      CPUWeight=1000
    '')
  ];
}
