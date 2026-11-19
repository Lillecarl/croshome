# shitbox's disk, boot and hardware: AMD Ryzen, Intel Arc for the host, an
# NVIDIA card passed through to the gaming VM (./vfio.nix).
#
# The disk was laid out by disko from ~/Code/nixos; this states what that
# produced, as plain values, because disko is only needed to format:
#
#   USB stick  ESP, partlabel USBEFI, mounted on /boot
#   2x SSD     mdraid1 "root" -> LUKS "crypted" -> LVM vg "pool"
#              pool/nixos  btrfs, subvolumes rootfs /home /nix /var /srv
#              pool/swap   swap
#              thin pools  VM disks, not mounted here
#
# The initrd unlocks LUKS, at the console or over SSH on :2222. ./contract.nix pins every value that matters
# here, checked with ./check-contract before activating a change.
{ lib, pkgs, ... }:
let
  pool = "/dev/pool/nixos";
  # noatime: on btrfs an atime update is a copy-on-write of the metadata tree.
  subvol = name: extra: {
    device = pool;
    fsType = "btrfs";
    options = [
      "subvol=${name}"
      "noatime"
    ]
    ++ extra;
  };
in
{
  fileSystems = {
    "/" = subvol "rootfs" [ "defaults" ];
    "/home" = subvol "/home" [ "compress=zstd" ];
    "/nix" = subvol "/nix" [ "compress=zstd" ];
    "/var" = subvol "/var" [ "defaults" ];
    "/srv" = subvol "/srv" [ "defaults" ];
    "/boot" = {
      device = "/dev/disk/by-partlabel/USBEFI";
      fsType = "vfat";
      options = [
        "umask=0077"
        "flush"
        "noatime"
        "errors=remount-ro"
      ];
    };
  };

  swapDevices = [
    {
      device = "/dev/pool/swap";
      priority = 25;
      discardPolicy = "both";
    }
  ];

  boot.swraid.enable = true;
  # mdmonitor wants MAILADDR or PROGRAM and has neither; it only nags.
  systemd.services.mdmonitor.enable = false;

  boot.initrd.luks.devices.crypted = {
    device = "/dev/disk/by-id/md-name-any:root-part1";
    allowDiscards = true;
    # AES runs on VAES here, so dm-crypt's work queues cost more latency than
    # the cipher. Baseline before this: 122 us mean QD1 4k read, 840 us fsync.
    bypassWorkqueues = true;
    # The TPM unlocks it when PCR 7 matches: Secure Boot on, our keys
    # (./secureboot.nix). The passphrase slot stays for the console and SSH.
    # Enrolled by hand:
    #   systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 <device>
    crypttabExtraOpts = [ "tpm2-device=auto" ];
  };
  services.lvm.boot.thin.enable = true;

  # The boot loader is lanzaboote: ./secureboot.nix.
  boot.loader.efi = {
    canTouchEfiVariables = true;
    efiSysMountPoint = "/boot";
  };

  boot.initrd = {
    availableKernelModules = [
      "ahci"
      "xhci_pci"
      "nvme"
      "sd_mod"
      "usbhid"
      "igc" # initrd SSH unlock over the onboard NIC
    ];
    kernelModules = [ "i915" ]; # vfio-pci: ./vfio.nix
    # systemd stage 1 (the only kind since nixpkgs 26.05). Remote unlock:
    # ssh -p 2222 root@<ip> lands in the password agent and asks for the
    # LUKS passphrase; boot continues once it is accepted.
    systemd = {
      users.root.shell = "/bin/systemd-tty-ask-password-agent";
      network = {
        enable = true;
        networks."10-boot" = {
          matchConfig.Driver = "igc";
          networkConfig.DHCP = "ipv4";
          dhcpV4Config.Hostname = "shitbox-boot";
        };
      };
    };
    network = {
      enable = true;
      # Stage 2 is NetworkManager; hand it a clean interface.
      flushBeforeStage2 = true;
      ssh = {
        enable = true;
        port = 2222;
        authorizedKeys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAHZ3pA0vIXiKQuwfM1ks8TipeOxfDT9fgo4xMi9iiWr lillecarl@lillecarl.com"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF4AwtWUz3usygb2J6owsUJs4X2yTchIGZyI+VDE76tF"
        ];
        # On the ESP, so they exist before anything is unlocked.
        hostKeys = [
          "/boot/ssh/ed25519"
          "/boot/ssh/rsa"
        ];
      };
    };
  };

  boot.kernelModules = [
    "kvm-amd"
    "i915"
    "nct6775" # ROG STRIX B550-F GAMING WIFI II sensors
  ];
  boot.kernelParams = [
    "i915.enable_guc=2"
    "acpi_enforce_resources=lax"
    "mitigations=off"
    "nohibernate"
  ];
  boot.blacklistedKernelModules = [
    "radeon"
    "nouveau"
    "nvidia"
    "nvidia_drm"
    "nvidia_modeset"
  ];

  hardware.cpu.amd.updateMicrocode = true;
  # mt7921e WiFi and Bluetooth need it.
  hardware.enableRedistributableFirmware = true;
  hardware.i2c.enable = true; # ddcutil
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver # Arc
      intel-vaapi-driver
    ];
  };
  powerManagement.cpuFreqGovernor = "performance";

  services.udev.extraRules = ''
    ACTION=="add|change", SUBSYSTEM=="block", ATTR{queue/scheduler}=="*kyber*", ATTR{queue/scheduler}="kyber"
    # Keep the SINOWEALTH mouse from waking the machine.
    SUBSYSTEM=="usb", ATTRS{idVendor}=="258a", ATTRS{idProduct}=="0033", ATTR{power/wakeup}="disabled"
  '';

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
