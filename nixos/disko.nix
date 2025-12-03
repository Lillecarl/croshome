{ ... }:
{
  disko.devices = {
    disk = {
      local = {
        type = "disk";
        device = "/dev/sda";
        content = {
          type = "gpt";
          partitions = {
            boot = {
              priority = 0;
              size = "1M";
              type = "EF02"; # This is the type for a BIOS boot partition
            };
            swap = {
              priority = 1;
              size = "16G";
              content = {
                type = "swap";
                discardPolicy = "both";
              };
            };
            primary = {
              priority = 2;
              size = "100%";
              content = {
                type = "lvm_pv";
                vg = "mainpool";
              };
            };
          };
        };
      };
    };
    lvm_vg = {
      mainpool = {
        type = "lvm_vg";
        lvs = {
          thinpool = {
            size = "100%";
            lvm_type = "thin-pool";
          };
          root = {
            priority = 2;
            size = "30G";
            content = {
              type = "btrfs";
              extraArgs = [ "-f" ];
              subvolumes =
                let
                  mountOptions = [
                    "defaults"
                    "compress=zstd"
                    "lazytime"
                    "ssd"
                    "autodefrag"
                  ];
                in
                {
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
