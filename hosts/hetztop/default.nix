{
  modulesPath,
  inputs,
  ...
}:
{
  imports = [
    ../../profiles/nixos/base.nix
    inputs.disko.nixosModules.disko
    inputs.home-manager.nixosModules.home-manager
    (modulesPath + "/profiles/qemu-guest.nix")
    ./disko.nix
    ./installscript.nix
    ../../profiles/nixos/podman.nix
    ../../profiles/nixos/ollama.nix
    ../../profiles/nixos/ttyd.nix
    ../../modules/nixos/pynixd.nix
    ./pynixd.nix
    ../../modules/nixos/ai-rebuild.nix
    ../../modules/nixos/btrfs.nix
    ./nix-gc.nix
    ../../modules/nixos/nix-gc-sudo.nix
    ../../profiles/nixos/terminfo.nix
    ../../secrets
  ];
  config = {
    users.users.lillecarl.extraGroups = [
      "wheel"
      "podman"
    ];
    home-manager.users.lillecarl = import ./home.nix;

    boot.loader.grub.enable = true;
    boot.initrd.availableKernelModules = [
      "ahci"
      "xhci_pci"
      "virtio_scsi"
    ];
    networking.hostName = "hetztop";
    networking.firewall.allowedTCPPorts = [
      4321
      8080
    ];
    nix.settings = {
      trusted-public-keys = [
        "hydra.nixos.org-1:CNHJZBh9K4tP3EKF6FkkgeVYsS3ohTl+oS0Qa8bezVs="
        "lillecarl.cachix.org-1:NN/LLMg7mbyvZCu32Qlo8LpSHqNw7Rr3VBCEYQvRpT0="
      ];
      substituters = [
        "https://lillecarl.cachix.org"
      ];
    };
    programs.ai-rebuild = {
      enable = true;
      pynixdVariant.enable = true;
      sudo.users = [ "lillecarl" ];
    };
    services.btrfs-housekeeping = {
      enable = true;
      sudoUsers = [ "lillecarl" ];
    };
    system.stateVersion = "25.11";
  };
}
