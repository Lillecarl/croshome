# The Linux builder guest, as a NixOS system.
#
# There is no disk. netboot.nix puts the store in a squashfs inside the initrd
# and overlays a tmpfs on it, so the whole machine is a kernel plus an initrd
# and the upper layer lives in RAM. That is affordable only because the host
# store is mounted alongside it: the guest starts with every path this Mac has
# already built or fetched, so the upper layer only ever holds what is new.
{
  modulesPath,
  config,
  lib,
  ...
}:
let
  cfg = config.vzBuilder;
  sharingHostStore = cfg.hostStore != "off";
in
{
  imports = [ "${modulesPath}/installer/netboot/netboot.nix" ];

  options.vzBuilder.hostStore = lib.mkOption {
    type = lib.types.enum [
      "off"
      "substituter"
      "overlay"
    ];
    default = "substituter";
    description = ''
      How the guest uses the host's /nix/store, which is mounted read-only at
      /host-nix together with the host's Nix database.

      - `off`: not mounted. Every input comes over the network or the wire.
      - `substituter`: the host store is a trusted substituter. Inputs are
        copied from it instead of cache.nixos.org -- no network and no
        signature round trip, but the bytes still land in the tmpfs upper
        layer.
      - `overlay`: a local-overlay store. The host store becomes the lower
        layer and nothing is copied at all, so RAM holds only new outputs.
        Experimental in Nix; see ./default.nix for the caveats.
    '';
  };

  config = lib.mkMerge [
    {
      system.stateVersion = "26.11";

      boot.kernelParams = [
        "console=hvc0" # vfkit's virtio-serial
        "systemd.log_level=warning"
      ];

      boot.initrd.availableKernelModules = [ "virtiofs" ];
      boot.kernelModules = [
        "virtiofs"
        "overlay"
      ];

      # x86_64-linux through Rosetta. The module mounts the virtiofs share the
      # host exposes, registers the binfmt handler with Apple's documented
      # flags, and adds x86_64-linux to extra-platforms -- which is what lets
      # one VM answer for both Linux systems.
      virtualisation.rosetta.enable = true;

      # The authorized key arrives on its own share rather than being baked in,
      # so the guest image stays generic and cacheable instead of being rebuilt
      # per machine. ./default.nix copies only the public half into it.
      fileSystems."/var/keys" = {
        device = "keys";
        fsType = "virtiofs";
        options = [ "ro" ];
      };

      # Socket activation, on TCP. systemd accepts any SOCK_STREAM so vsock
      # would work identically, but vsock needs a ProxyCommand in root's ssh
      # config and the nix-daemon is what dials out. Over the NAT interface no
      # privileged host configuration is required at all.
      services.openssh = {
        enable = true;
        startWhenNeeded = true;
        settings.PasswordAuthentication = false;
        authorizedKeysFiles = lib.mkForce [ "/var/keys/builder_ed25519.pub" ];
      };

      # The fixed keypair nixpkgs ships for its own builder VM. nix-darwin
      # hardcodes the matching public half as `publicHostKey`, so reusing it
      # means the host verifies this VM with a value it already trusts.
      environment.etc."ssh/ssh_host_ed25519_key" = {
        mode = "0600";
        source = "${modulesPath}/profiles/keys/ssh_host_ed25519_key";
      };
      environment.etc."ssh/ssh_host_ed25519_key.pub" = {
        mode = "0644";
        source = "${modulesPath}/profiles/keys/ssh_host_ed25519_key.pub";
      };

      users.users.builder = {
        isNormalUser = true;
        group = "builder";
      };
      users.groups.builder = { };

      # How the host finds this machine. macOS bootpd records the DHCP hostname
      # in /var/db/dhcpd_leases but serves no DNS, so DHCP alone resolves
      # nothing. mDNS does: mDNSResponder answers <hostName>.local natively,
      # with nothing configured on the host side.
      networking.hostName = "vzbuilder";
      networking.useDHCP = true;
      services.avahi = {
        enable = true;
        publish = {
          enable = true;
          addresses = true;
          workstation = true;
        };
      };

      nix.settings = {
        trusted-users = [ "builder" ];
        experimental-features = [
          "nix-command"
          "flakes"
        ];
      };

      # A builder evaluates nothing, so it needs no docs.
      documentation.enable = false;
      documentation.nixos.enable = false;
      services.getty.autologinUser = "root";
    }

    # The host store and the host's Nix database. Both are needed: a path on
    # disk that no database knows about is invisible to Nix.
    (lib.mkIf sharingHostStore {
      fileSystems."/host-nix/nix/store" = {
        device = "hoststore";
        fsType = "virtiofs";
        options = [
          "nofail"
          "ro"
        ];
      };
      fileSystems."/host-nix/nix/var/nix/db" = {
        device = "hostdb";
        fsType = "virtiofs";
        options = [
          "nofail"
          "ro"
        ];
      };
    })

    (lib.mkIf (cfg.hostStore == "substituter") {
      # `trusted=1` because nothing in the host store is signed for this guest.
      # It is the same store the build is for, reached over a read-only mount,
      # so there is no third party whose signature would mean anything.
      nix.settings.extra-substituters = [ "local?root=/host-nix&trusted=1" ];
    })

    (lib.mkIf (cfg.hostStore == "overlay") {
      nix.settings.experimental-features = [ "local-overlay-store" ];

      # netboot.nix already overlays a tmpfs on the squashfs store. This adds
      # the host store underneath as a second lower layer, so Nix can reference
      # host paths in place instead of copying them into RAM.
      fileSystems."/nix/store" = lib.mkForce {
        overlay = {
          lowerdir = [
            "/nix/.ro-store"
            "/host-nix/nix/store"
          ];
          upperdir = "/nix/.rw-store/store";
          workdir = "/nix/.rw-store/work";
        };
        neededForBoot = true;
      };
    })
  ];
}
