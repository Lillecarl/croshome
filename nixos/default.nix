{
  pkgs,
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
    ./podman.nix
  ];
  config = {
    boot.loader.grub.enable = true;
    boot.initrd.availableKernelModules = [
      "ahci"
      "xhci_pci"
      "virtio_scsi"
    ];
    boot.kernelPackages = pkgs.linuxPackages_latest;
    # Support building crossPlatform with QEMU
    boot.binfmt.emulatedSystems = [
      {
        "x86_64-linux" = "aarch64-linux";
        "aarch64-linux" = "x86_64-linux";
      }
      .${pkgs.stdenv.hostPlatform.system}
    ];
    # Terminfo packages for terminals we're using
    environment.systemPackages = with pkgs.pkgsBuildBuild; [
      foot.terminfo
      tmux.terminfo
    ];
    networking.hostName = "hetztop";
    environment.etc.nixpkgs.source = inputs.nixpkgs.outPath;
    nix = {
      settings = {
        trusted-users = [ "lillecarl" ];
        experimental-features = [
          "nix-command"
          "flakes"
          "read-only-local-store"
        ];
        sandbox = "relaxed";
      };
      package = pkgs.lixPackageSets.latest.lix;
      nixPath = [
        "nixpkgs=/etc/nixpkgs"
      ];
      registry = {
        nixpkgs.flake = inputs.nixpkgs;
        n.flake = inputs.nixpkgs;
      };
    };
    nixpkgs = {
      config.allowUnfree = true;
    };
    programs.mosh = {
      enable = true;
      openFirewall = true;
    };
    services.openssh = {
      enable = true;
      openFirewall = true;
    };
    system.stateVersion = "25.11";
  };
}
