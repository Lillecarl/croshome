# Two 1 TB Samsung PM9A1 NVMe drives. Everything redundant, at two layers:
#
#  - `/boot`: two independent 1 GB ESPs, one per drive, *not* mdadm-mirrored.
#    `bootctl install` refuses an md array outright -- it needs its target to
#    be a real GPT partition on a real disk to register a UEFI NVRAM entry,
#    and an md array is neither. So nvme0's ESP is the one NixOS's own
#    systemd-boot installer manages at `/boot`, nvme1's ESP mounts on the side
#    at `/boot-mirror`, and ../boot-mirror.nix keeps it in sync by hand after
#    every switch: this is systemd-boot's answer to what GRUB's
#    `mirroredBoots` does natively, one independent bootloader install per
#    disk rather than one install onto a mirrored block device.
#
#  - Data: mdadm RAID1, LUKS2 on top of the array (not per-disk -- one volume,
#    one passphrase, mirrored underneath it), then LVM on the open volume.
#    `initrdUnlock` (disko's default) wires the passphrase prompt into
#    `boot.initrd.luks.devices` automatically, and ../initrd-ssh.nix is what
#    makes that prompt answerable over the network instead of only at a
#    physical console. A mirror underneath means a dead drive costs capacity,
#    not data or the ability to unlock. Two logical volumes ride the decrypted
#    PV: `root`, btrfs with the same subvolume scheme ../hetztop runs
#    (`@root`, `@nix`, `@home`), and `thinpool`, a thin pool left unformatted
#    for VM disks -- the reason for LVM here at all. TopoLVM allocates out of
#    it now, one logical volume per PersistentVolumeClaim; see
#    ../../kube/modules/topolvm.nix. Both sizes are LVM, so wrong is a resize
#    away, not a reinstall.
#
# Swap sits outside the mirror and the LUKS volume entirely -- 48 GiB on each
# drive, 96 GiB total, half again the 64 GiB of RAM, both enabled at equal
# priority so pages stripe across them; losing a drive drops half of it, which
# is acceptable for swap. `randomEncryption` still covers it: a fresh key every
# boot, discarded on poweroff, keeps whatever was paged out from surviving on
# an unencrypted disk without needing a passphrase prompt for something that
# holds no state worth unlocking.
{ ... }:
let
  mountOptions = [
    "defaults"
    "compress=zstd"
    "lazytime"
    "ssd"
    "autodefrag"
  ];
  swapSize = "48G";
in
{
  disko.devices = {
    disk = {
      nvme0 = {
        type = "disk";
        device = "/dev/nvme0n1";
        content = {
          type = "gpt";
          partitions = {
            boot = {
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
              };
            };
            swap = {
              size = swapSize;
              content = {
                type = "swap";
                discardPolicy = "both";
                randomEncryption = true;
              };
            };
            root = {
              size = "100%";
              content = {
                type = "mdraid";
                name = "root";
              };
            };
          };
        };
      };
      nvme1 = {
        type = "disk";
        device = "/dev/nvme1n1";
        content = {
          type = "gpt";
          partitions = {
            boot = {
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot-mirror";
                mountOptions = [ "umask=0077" ];
              };
            };
            swap = {
              size = swapSize;
              content = {
                type = "swap";
                discardPolicy = "both";
                randomEncryption = true;
              };
            };
            root = {
              size = "100%";
              content = {
                type = "mdraid";
                name = "root";
              };
            };
          };
        };
      };
    };
    mdadm = {
      root = {
        type = "mdadm";
        level = 1;
        content = {
          type = "luks";
          name = "cryptroot";
          # No keyFile/passwordFile: disko asks for a passphrase at format
          # time and NixOS prompts for it again at every boot via
          # boot.initrd.luks.devices.cryptroot, which disko wires up on its
          # own (initrdUnlock defaults to true). ../initrd-ssh.nix is what
          # makes that boot-time prompt reachable over ssh.
          settings.allowDiscards = true;
          content = {
            type = "lvm_pv";
            vg = "mainpool";
          };
        };
      };
    };
    lvm_vg = {
      mainpool = {
        type = "lvm_vg";
        lvs = {
          # Left unformatted on purpose. TopoLVM carves thin volumes out of
          # this, one per PersistentVolumeClaim, so what is in it is decided by
          # the cluster rather than declared here.
          thinpool = {
            size = "100%";
            lvm_type = "thin-pool";
          };
          root = {
            # Ahead of thinpool: a thin-pool's "100%" claims whatever is left
            # once earlier LVs have taken their share, not the whole VG.
            priority = 0;
            size = "250G";
            content = {
              type = "btrfs";
              extraArgs = [ "-f" ];
              subvolumes = {
                "@root" = {
                  mountpoint = "/";
                  inherit mountOptions;
                };
                "@nix" = {
                  mountpoint = "/nix";
                  inherit mountOptions;
                };
                "@home" = {
                  mountpoint = "/home";
                  inherit mountOptions;
                };
              };
            };
          };
        };
      };
    };
  };
}
