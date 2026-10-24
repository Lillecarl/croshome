{
  config,
  pkgs,
  modulesPath,
  inputs,
  ...
}:
{
  imports = [
    ../../profiles/nixos/base.nix
    (modulesPath + "/profiles/qemu-guest.nix")
    ./disko.nix
    ./pynixd.nix
    ./nix-gc.nix
    ./postgres.nix
    ./secrets.nix
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
    # The front door for everything public on this host: dex, and one
    # oauth2-proxy in front of each app. ../../modules/nixos/gate.nix has the
    # shape, and why it is that shape.
    #
    # Caddy gets the certificates over HTTP-01, so these names have to resolve
    # to this machine before the first switch. They are Cloudflare records for
    # lillecarl.com, and nothing here creates them:
    #
    #   dex.snurr.lillecarl.com   A 65.108.150.98
    #   *.snurr.lillecarl.com     A 65.108.150.98
    #
    # A record and no AAAA: this host's only global address is 65.108.150.98/32
    # on enp1s0.
    services.gate = {
      enable = true;
      baseDomain = "snurr.lillecarl.com";
      acmeEmail = "git@lillecarl.com";
      cookieSecretFile = config.age.secrets.gate-cookie-secret.path;
      idp = {
        # The login dex checks, not a mailbox: nothing is ever sent to it.
        email = "git@lillecarl.com";
        username = "lillecarl";
        passwordHashFile = config.age.secrets.dex-password-hash.path;
      };
      apps.app = {
        # Nothing serves this yet. A static 200 is what an authenticated
        # request gets, which is exactly enough to prove that the login works
        # before the webapp exists; point it at the app's loopback address --
        # `http://127.0.0.1:3000` -- when there is one.
        upstream = "static://200";
        clientSecretFile = config.age.secrets.dex-client-app.path;
      };
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
