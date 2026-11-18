{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.boot.initrd.wireguard;
  netdev = "20-${cfg.interface}";
in
{
  options.boot.initrd.wireguard = {
    enable = lib.mkEnableOption "a WireGuard tunnel in the systemd initrd, so a remote unlock works behind NAT";
    interface = lib.mkOption {
      type = lib.types.str;
      default = "wg-initrd";
      description = "The tunnel's name. The initrd deletes it before stage 2.";
    };
    privateKeyFile = lib.mkOption {
      type = lib.types.str;
      example = "/etc/secrets/initrd/wg.key";
      description = ''
        Absolute path, outside the store, to the key from `wg genkey`. The
        bootloader install copies it into the initrd as a secret, so the file
        must exist before the first switch, and it is plaintext on the boot
        partition. Give it a key of its own, not one stage 2 uses.
      '';
    };
    address = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      example = [ "10.44.33.3/24" ];
      description = "The tunnel's addresses.";
    };
    peers = lib.mkOption {
      type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
      example = [
        {
          PublicKey = "...";
          Endpoint = "198.51.100.1:51820";
          AllowedIPs = [ "10.44.33.1/32" ];
          PersistentKeepalive = 25;
        }
      ];
      description = "`[WireGuardPeer]` sections, as `systemd.network.netdevs.<name>.wireguardPeers` takes them.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.boot.initrd.systemd.network.enable;
        message = "boot.initrd.wireguard needs boot.initrd.systemd.network.";
      }
    ];

    # networkd imports this credential for the netdev by name. In the initrd
    # /etc stays behind at switch-root, and /run would not.
    boot.initrd.secrets."/etc/credstore/network.wireguard.private.${netdev}" = cfg.privateKeyFile;
    boot.initrd.availableKernelModules = [ "wireguard" ];

    boot.initrd.systemd.network = {
      netdevs.${netdev} = {
        netdevConfig = {
          Kind = "wireguard";
          Name = cfg.interface;
        };
        wireguardPeers = cfg.peers;
      };
      networks.${netdev} = {
        matchConfig.Name = cfg.interface;
        inherit (cfg) address;
      };
    };

    # networkd leaves a netdev in place when it stops, so stage 2 would
    # inherit a live tunnel that holds the initrd's key.
    boot.initrd.systemd.storePaths = [ (lib.getExe' pkgs.iproute2 "ip") ];
    boot.initrd.systemd.services.initrd-wireguard-teardown = {
      description = "Delete ${cfg.interface} before stage 2";
      wantedBy = [ "initrd.target" ];
      after = [ "systemd-networkd.service" ];
      conflicts = [
        "initrd-switch-root.target"
        "shutdown.target"
      ];
      before = [
        "initrd-switch-root.target"
        "shutdown.target"
      ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "/bin/true";
        ExecStop = "-${lib.getExe' pkgs.iproute2 "ip"} link delete ${cfg.interface}";
      };
    };
  };
}
