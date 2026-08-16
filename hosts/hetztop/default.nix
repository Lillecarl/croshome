{
  pkgs,
  lib,
  modulesPath,
  inputs,
  homeArgs,
  ...
}:
{
  imports = [
    inputs.disko.nixosModules.disko
    inputs.home-manager.nixosModules.home-manager
    (modulesPath + "/profiles/qemu-guest.nix")
    ./disko.nix
    ./installscript.nix
    ./podman.nix
    ./ollama.nix
    ./ttyd.nix
    # pynixd moved into the nanopynix monorepo, so its NixOS module comes from
    # that input rather than a checkout of its own. nanopynix is `flake = false`,
    # so this is the source tree and no second flake is evaluated.
    "${inputs.nanopynix}/pynixd/nix/nixos"
    ./pynixd.nix
    ./ai-rebuild.nix
    ./btrfs.nix
    ./nix-gc.nix
    ./terminfo.nix
  ];
  config = {
    # The account and the home-manager wiring used to live in ../home, next to
    # the modules it pulls in. It is host state -- a password hash, a uid, the
    # groups this machine has -- so it belongs to the host now that ../../home
    # is shared with the MacBook and ChromeOS.
    programs.fish.enable = true;
    users.users.lillecarl = {
      extraGroups = [
        "wheel"
        "podman"
      ];
      hashedPassword = "$y$j9T$U4zBBS9RMV9YMttHauO8k0$V.KT/P/AdBTXXT8f6p9EIlCsZV5UnaPDgEVtUvUJU3C";
      isNormalUser = true;
      openssh.authorizedKeys.keyFiles = [ ../../lillecarl.pub ];
      shell = pkgs.fish;
    };
    home-manager = {
      useGlobalPkgs = true;
      extraSpecialArgs = homeArgs;
      users.lillecarl = import ./home.nix;
    };

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
    # reference catppuccin whiskers so it doesn't get garbage collected every time you collect garbage.
    environment.etc.catppucin-whiskers.source =
      inputs.catppuccin.packages.${pkgs.stdenv.hostPlatform.system}.whiskers;
    networking.hostName = "hetztop";
    networking.firewall.allowedTCPPorts = [
      4321
      8080
    ];
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
          "lillecarl.cachix.org-1:NN/LLMg7mbyvZCu32Qlo8LpSHqNw7Rr3VBCEYQvRpT0="
        ];
        substituters = [
          "https://nix-csi.cachix.org"
          "https://lillecarl.cachix.org"
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
    services.btrfs.autoScrub = {
      enable = true;
      interval = "monthly";
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
