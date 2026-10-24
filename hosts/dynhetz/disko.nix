# Two 1 TB Samsung PM9A1 NVMe drives. Redundant where it matters:
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
#  - Data: LVM over two LUKS2 volumes, one per drive, one passphrase:
#    `cryptnvme0` and `cryptnvme1`, named after disko's disks. The names live
#    on in the GPT partition labels (`disk-nvme0-root`), which is what the
#    initrd opens by. The kernel numbers the drives the other way round on
#    this box: `disk-nvme0-root` is /dev/nvme1n1p3. Match a partition by its
#    label, never by the kernel name. `initrdUnlock` (disko's default) wires
#    both into `boot.initrd.luks.devices`; systemd-cryptsetup caches the
#    passphrase, so one answer opens both, and ../initrd-ssh.nix makes the
#    prompt answerable over the network. ./vm-test-ssh-unlock.nix proves both.
#
#    `root` is LVM raid1 across the two PVs, btrfs with the same subvolume
#    scheme ../hetztop runs (`@root`, `@nix`, `@home`): a dead drive costs
#    capacity, not the system. The rest of the VG is for TopoLVM, thick and
#    unmirrored, one logical volume per PersistentVolumeClaim (see
#    ../../kube/modules/topolvm.nix). No thin pool: a thin pool cannot shrink,
#    so one sized to the free space fixes every other LV for good.
#    dmeventd watches the raid1 and logs a failed leg to the journal; nothing
#    mails about it.
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
  # No keyFile/passwordFile: disko asks for the passphrase at format time and
  # the initrd asks for it at every boot.
  luksPV = name: {
    type = "luks";
    inherit name;
    settings.allowDiscards = true;
    content = {
      type = "lvm_pv";
      vg = "mainpool";
    };
  };
in
{
  services.lvm.dmeventd.enable = true;

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
              content = luksPV "cryptnvme0";
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
              content = luksPV "cryptnvme1";
            };
          };
        };
      };
    };
    lvm_vg = {
      mainpool = {
        type = "lvm_vg";
        lvs = {
          root = {
            size = "500G";
            lvm_type = "raid1";
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
