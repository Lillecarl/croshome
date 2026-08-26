# Test-only overrides for disko's own NixOS-VM-test harness. NOT imported by
# ./default.nix -- these shrink the real 48G-per-disk swap and 250G root LV
# to fit the harness's disks, which would be wrong on the physical machine,
# so they only ever apply to a second, throwaway evaluation built like this:
#
#   nix-build --expr '
#     let
#       outer = import ./.;
#       base = outer.dynhetzSystem { system = "aarch64-linux"; };
#       test = base.extendModules { modules = [ ./hosts/dynhetz/vm-test.nix ]; };
#       diskoLib = test._module.args.diskoLib;
#       cfg = test.config.disko;
#       installTest = diskoLib.testLib.makeDiskoTest {
#         inherit (test) extendModules;
#         pkgs = test._module.args.pkgs;
#         name = "dynhetz-disko";
#         disko-config = builtins.removeAttrs test.config [ "_module" ];
#         testMode = "direct";
#         bootCommands = cfg.tests.bootCommands;
#         efi = cfg.tests.efi;
#         enableOCR = cfg.tests.enableOCR;
#         extraSystemConfig = cfg.tests.extraConfig;
#         extraTestScript = cfg.tests.extraChecks;
#         # disko's own module.nix hardcodes 4G-per-disk here with no knob to
#         # raise it (lib/tests.nix: `emptyDiskImages = genList (_: 4096)
#         # num-disks`) -- too small to say anything about a 250G root LV even
#         # shrunk, so this calls makeDiskoTest directly instead of going
#         # through `config.system.build.installTest`, purely to reach the one
#         # extra parameter that raises it.
#         extraInstallerConfig = {
#           virtualisation.emptyDiskImages = outer.lib.mkForce [ 10240 10240 ];
#         };
#       };
#     in installTest.extend {
#       modules = [{ requiredFeatures.kvm = false; requiredFeatures."nixos-test" = false; }];
#     }
#   '
#
# `installTest` (disko's module.nix, reconstructed above) partitions two
# throwaway virtio disks with the real disko script -- exercising the mdadm
# RAID1 assembly, the LUKS unlock and the LVM/btrfs layout exactly as they
# run on the physical machine -- boots the installed closure, and runs
# ./disko.tests.extraChecks below.
#
# `extendModules` re-evaluates the whole configuration with this module
# folded in, so `disko.devices` -- what `installTest` partitions -- already
# carries the shrunk swap and root LV. `disko.tests.extraConfig` looked like
# the sanctioned patch point at first, but it only reaches the *installed*
# system's module tree (post-format), not the disko-format step itself,
# which reads `config.disko.devices` straight off the top-level eval; a
# same-size 48G swap or 250G root LV on a 10G test disk fails there before
# boot is ever reached.
#
# aarch64-linux rather than the real x86_64-linux target: none of what this
# checks (disk layout, boot, agenix) is architecture-specific, and aarch64
# runs natively on the VZ builder instead of under Rosetta emulation. The
# `requiredFeatures` extension drops disko's hard "kvm" + "nixos-test"
# requirement: nothing in this environment offers hardware-accelerated
# virtualization for a nested Linux guest, so the run falls back to qemu's
# software emulation (nixos' own qemu-common.nix already requests
# `accel=kvm:tcg`, so this is a scheduling constraint, not a runtime one).
{ lib, ... }:
{
  disko.testMode = true;

  # 10G per disk (see the invocation above) -- generous enough for a root LV
  # and thin pool worth looking at, not so large the test drags.
  disko.devices.disk.nvme0.content.partitions.swap.size = lib.mkForce "256M";
  disko.devices.disk.nvme1.content.partitions.swap.size = lib.mkForce "256M";

  # AMD microcode is x86_64-only, and the aarch64-linux test run above trips
  # its platform guard the moment this evaluates -- the package itself is
  # unavailable on aarch64-linux, not just untested there.
  hardware.cpu.amd.updateMicrocode = lib.mkForce false;

  # ./disko.nix's root volume asks for a passphrase interactively -- correct
  # for the real machine, useless for an unattended test. `settings.keyFile`
  # is disko's own escape hatch for exactly this: disko's test harness
  # (lib/tests.nix) already embeds `/tmp/secret.key` = "secretsecret" into
  # every installTest's initrd unconditionally, at both the disko-format step
  # and (because `settings` feeds straight into
  # `boot.initrd.luks.devices.cryptroot`) the real boot-time unlock too. This
  # is additive, not an override -- ./disko.nix sets `settings.allowDiscards`
  # only, so there is no existing `keyFile` definition to conflict with.
  disko.devices.mdadm.root.content.settings.keyFile = "/tmp/secret.key";

  # ./disko.nix's root LV is a fixed 250G, sized for the real ~900G VG left
  # after boot and swap on a 1TB disk. Even at 10G-per-disk the test VG has
  # nowhere near that, so this shrinks to something it can actually hold;
  # thinpool's "100%" still claims whatever is left over.
  disko.devices.lvm_vg.mainpool.lvs.root.size = lib.mkForce "4G";

  # ../initrd-ssh.nix's hostKeys points at a path on the real machine's own
  # disk, read at *activation* time (`boot.initrd.secrets` copies it inside
  # the chroot when `switch-to-configuration boot` runs) -- not at build
  # time, and not from wherever this Nix expression happens to be evaluated.
  # A checked-in test key doesn't help: whatever path it names still has to
  # exist inside the guest's /mnt at that exact moment, and disko's test
  # harness (lib/tests.nix) exposes no hook to stage a file there before that
  # step runs -- `postDisko` would do it but isn't threaded through
  # `disko.tests.*` by module.nix's own `installTest`. So for this
  # regression test sshd simply runs without a host key; nothing here uses
  # ssh (LUKS unlock goes through settings.keyFile above), and a real host
  # key genuinely existing on the physical machine is not something a VM
  # test run from a checkout can stand in for -- see the session notes on
  # verifying the ssh-unlock path for real, separately.
  boot.initrd.network.ssh.hostKeys = lib.mkForce [ ];
  boot.initrd.network.ssh.ignoreEmptyHostKeys = lib.mkForce true;

  disko.tests.extraChecks = ''
    machine.wait_for_unit("multi-user.target")
    print(machine.succeed("cat /proc/mdstat"))
    print(machine.succeed("cryptsetup status cryptroot"))
    print(machine.succeed("vgs; lvs"))
    for mp in ["/nix", "/home", "/", "/boot", "/boot-mirror"]:
        print(machine.succeed(f"findmnt {mp}"))
    machine.succeed("systemctl is-active sshd.service")

    # home-manager-lillecarl.service fails only under this harness: its
    # nix-daemon can't chown paths on the 9p-shared /nix/store the harness
    # bind-mounts in for speed ("changing ownership of path ... Invalid
    # argument"). A real install has a normal local writable store, so this
    # is a known artifact of the test, not of the host config.
    failed = machine.succeed(
        "systemctl --failed --no-legend | grep -v home-manager-lillecarl.service || true"
    )
    assert failed.strip() == "", f"failed units after boot: {failed}"
  '';
}
