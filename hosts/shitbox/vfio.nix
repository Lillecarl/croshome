# The Windows gaming VM: the NVIDIA card bound to vfio-pci at boot, libvirt,
# and a hook that reserves hugepages and pins the host to one core while the
# VM runs.
#
# The domain itself (win11-4) is libvirt state under /var/lib/libvirt, defined
# once by NixVirt from ~/Code/nixos and kept there; this config does not
# redefine it. resources/gamingvm.xml.nix in that repository is the source if
# it ever needs defining again.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  vm = "win11-4";
  memoryMiB = 14336;
  # 2M pages for the VM, plus 64 (128MiB) for overhead.
  hugepages = memoryMiB / 2 + 64;
  compactionDefault = 20;

  systemctl = "${config.systemd.package}/bin/systemctl";
  virsh = "${pkgs.libvirt}/bin/virsh";
  sysctl = lib.getExe pkgs.sysctl;
  slices = [
    "init.scope"
    "system.slice"
    "user.slice"
  ];
  pin = cpus: lib.concatMapStringsSep "\n" (s: "${systemctl} set-property --runtime -- ${s} AllowedCPUs=${cpus}") slices;

  hook = pkgs.writeShellScript "${vm}-hook" ''
    # https://libvirt.org/hooks.html#etc-libvirt-hooks-qemu
    vmname=$1 event=$2
    [ "$vmname" = ${vm} ] || exit 0

    case $event in
      prepare)
        ${sysctl} -w vm.compaction_proactiveness=1
        echo 3 > /proc/sys/vm/drop_caches
        echo 1 > /proc/sys/vm/compact_memory
        ${virsh} allocpages 2M ${toString hugepages} || {
          echo "failed to allocate hugepages for ${vm}" >&2
          exit 1
        }
        ;;
      started)
        pgid=$(ps -o pgid= "$(cat /var/run/libvirt/qemu/${vm}.pid)" | tr -d ' ')
        ${pkgs.util-linux}/bin/renice -1 -g "$pgid"
        # Linux keeps the 6th physical core; the VM gets the rest.
        ${pin "5,11"}
        ;;
      release)
        ${virsh} allocpages 2M 0
        ${pin "0-11"}
        ${sysctl} -w vm.compaction_proactiveness=${toString compactionDefault}
        ;;
    esac
  '';
in
{
  boot.initrd.kernelModules = [ "vfio-pci" ];
  boot.kernelModules = [
    "vfio"
    "vfio_pci"
    "vfio_iommu_type1"
  ];
  boot.kernelParams = [
    "amd_iommu=on"
    "iommu=pt"
    "kvm.ignore_msrs=1"
    "vfio_iommu_type1.allow_unsafe_interrupts=1"
  ];
  # The RTX card (10de:2487) and its audio function (10de:228b).
  boot.extraModprobeConfig = ''
    options vfio-pci ids=10de:2487,10de:228b
    options kvm ignore_msrs=1 report_ignored_msrs=0
    softdep amdgpu pre: vfio_pci
    softdep i915 pre: vfio_pci
    softdep nvidia pre: vfio_pci
  '';

  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      swtpm.enable = true;
      vhostUserPackages = [ pkgs.virtiofsd ];
    };
    hooks.qemu.${vm} = hook;
  };
  programs.virt-manager.enable = true;
  users.users.lillecarl.extraGroups = [ "libvirtd" ];

  environment.systemPackages = [ pkgs.looking-glass-client ];

  # libinput ignores the device remapper feeds the VM (home/remapper.nix).
  services.udev.packages = [ pkgs.remapper.plugins.libvirt ];
}
