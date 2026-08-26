# systemd-boot's own installer refuses an mdadm-mirrored ESP outright:
# `bootctl install` needs its target to be a real GPT partition on a real
# disk so it can register a UEFI NVRAM entry, and an md array is neither --
# "File system ... is not located on a partitioned block device." disko's own
# example for a mirrored ESP (example/boot-raid1.nix) pairs it with GRUB's
# `mirroredBoots`, which runs one independent bootloader install per disk;
# systemd-boot has no equivalent built in, so ./disko.nix gives nvme1's ESP
# to this module instead of to mdadm, and this reinstates the mirroring by
# hand: after the stock installer finishes with nvme0's ESP as normal, rsync
# its contents onto nvme1's plain, independent ESP and register that one with
# bootctl too. Two disks, two real NVRAM entries, no md array involved in
# either -- exactly grub's redundancy model, aimed at systemd-boot.
#
# `extraInstallCommands` is the hook: systemd-boot.nix splices it straight
# into its own installer script, after the stock install/update call. Reading
# back `config.system.build.installBootLoader` to wrap it, the more obvious
# route, is a dead end -- that option is what *this* module would also be
# defining, and referencing it here is a genuine infinite recursion, not
# just a laziness problem.
{ config, lib, pkgs, ... }:
let
  cfg = config.boot.loader.systemd-boot;
  espMain = config.boot.loader.efi.efiSysMountPoint;
  espMirror = "/boot-mirror";
  graceful = lib.optionalString cfg.graceful "--graceful";
in
{
  config = lib.mkIf cfg.enable {
    boot.loader.systemd-boot.extraInstallCommands = ''
      if ${pkgs.util-linux}/bin/mountpoint -q ${espMirror}; then
        if ! (
          set -e
          ${pkgs.rsync}/bin/rsync -a --delete ${espMain}/ ${espMirror}/
          if [ "''${NIXOS_INSTALL_BOOTLOADER:-}" = 1 ]; then
            ${config.systemd.package}/bin/bootctl --esp-path=${espMirror} ${graceful} install
          else
            ${config.systemd.package}/bin/bootctl --esp-path=${espMirror} ${graceful} update
          fi
        ); then
          echo "" >&2
          echo "boot-mirror: failed to refresh the secondary ESP at ${espMirror}." >&2
          echo "  nvme0 is current and this machine still boots from it, but nvme1" >&2
          echo "  alone would not. Rerun the switch to retry." >&2
        fi
      else
        echo "boot-mirror: ${espMirror} is not mounted; skipping the secondary ESP." >&2
      fi
    '';
  };
}
