{
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
    ./podman.nix
    ./ollama.nix
    ./ttyd.nix
    ./ai-rebuild.nix
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
    time.timeZone = "Europe/Stockholm";
    # Terminfo packages for terminals we're using
    environment.systemPackages = with pkgs.pkgsBuildBuild; [
      foot.terminfo
    ];
    networking.hostName = "hetztop";
    networking.firewall.allowedTCPPorts = [ 4321 8080 ];
    environment.etc.nixpkgs.source = inputs.nixpkgs.outPath;
    # environment.etc."profile.d/claude.sh".text = ''
    programs.bash.shellInit = lib.mkBefore ''
      if [ -n "$CLAUDECODE" ]; then
        eval "$(DIRENV_LOG_FORMAT= ${lib.getExe pkgs.direnv} hook bash)"
        unset HTTPS_PROXY
      fi
    '';
    nix = {
      settings = {
        trusted-users = [ "lillecarl" ];
        experimental-features = [
          "nix-command"
          "flakes"
          "read-only-local-store"
          "ca-derivations"
          "dynamic-derivations"
          "recursive-nix"
        ];
        trusted-public-keys = [
          "hydra.nixos.org-1:CNHJZBh9K4tP3EKF6FkkgeVYsS3ohTl+oS0Qa8bezVs="
          "nix-csi.cachix.org-1:i4w33gR4efO67jpz8U7g/MdvRQ6mQ3LEF9fB8tES60g="
        ];
        substituters = [
          "https://nix-csi.cachix.org"
        ];
        sandbox = "relaxed";
      };
      # package = pkgs.lixPackageSets.latest.lix;
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
