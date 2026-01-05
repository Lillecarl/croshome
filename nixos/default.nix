{
  config,
  pkgs,
  lib,
  modulesPath,
  inputs,
  ...
}:
{
  imports = [
    inputs.disko.nixosModules.disko
    inputs.home-manager.nixosModules.home-manager
    (modulesPath + "/profiles/qemu-guest.nix")
    ../home
    ./disko.nix
    ./installscript.nix
  ];
  config = {
    boot.loader.grub.enable = true;
    boot.initrd.availableKernelModules = [ "ahci" "xhci_pci" "virtio_scsi" ];
    boot.kernelPackages = pkgs.linuxPackages_latest;
    environment.systemPackages = with pkgs.pkgsBuildBuild; [
      foot.terminfo
      tmux.terminfo
    ];
    networking.hostName = "hetztop";
    nix = {
      settings.experimental-features = [ "nix-command" "flakes" "read-only-local-store" ];
      package = pkgs.lixPackageSets.latest.lix;
    };
    nixpkgs = {
      config.allowUnfree = true;
    };
    services.openssh = {
      enable = true;
      openFirewall = true;
    };
    system.stateVersion = "25.11";
  };
}
