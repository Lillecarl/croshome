{
  config,
  lib,
  pkgs,
  utils,
  ...
}:

let
  cfg = config.boot.initrd.wifi;
  conf = "/etc/wpa_supplicant/initrd.conf";
  device = "sys-subsystem-net-devices-${utils.escapeSystemdPath cfg.interface}.device";
in
{
  options.boot.initrd.wifi = {
    enable = lib.mkEnableOption "wpa_supplicant in the systemd initrd, so a remote unlock works without a cable";
    interface = lib.mkOption {
      type = lib.types.str;
      example = "wlp7s0";
      description = ''
        The wireless interface, by the name udev gives it. The initrd uses
        the same naming as stage 2. Give it an address with
        `boot.initrd.systemd.network.networks`.
      '';
    };
    kernelModules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      example = [ "mt7921e" ];
      description = ''
        The driver modules. The initrd takes the firmware each one names from
        `hardware.firmware`.
      '';
    };
    configFile = lib.mkOption {
      type = lib.types.str;
      example = "/etc/secrets/initrd/wpa_supplicant.conf";
      description = ''
        Absolute path, outside the store, to a wpa_supplicant configuration
        with the network blocks. The bootloader install copies it into the
        initrd as a secret, so the file must exist before the first switch,
        and it is plaintext on the boot partition.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    boot.initrd.availableKernelModules = cfg.kernelModules;
    # mac80211 asks the crypto API for these at key install, even with a
    # driver that encrypts in hardware, and the module closure cannot see
    # that request. Without them: "nl80211: kernel reports: key addition failed".
    boot.initrd.kernelModules = [
      "aes"
      "ccm"
      "ctr"
      "cmac"
      "gcm"
    ];
    boot.initrd.secrets.${conf} = cfg.configFile;
    boot.initrd.systemd.storePaths = [ "${pkgs.wpa_supplicant}/bin/wpa_supplicant" ];

    boot.initrd.systemd.services.initrd-wpa-supplicant = {
      description = "WPA supplicant on ${cfg.interface} in the initrd";
      wantedBy = [ "initrd.target" ];
      bindsTo = [ device ];
      requires = [ "initrd-nixos-copy-secrets.service" ];
      after = [
        device
        "initrd-nixos-copy-secrets.service"
      ];
      # Stage 2 brings its own WiFi stack, so the interface is handed over
      # with no supplicant left on it.
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
        ExecStart = "${pkgs.wpa_supplicant}/bin/wpa_supplicant -D nl80211 -i ${cfg.interface} -c ${conf}";
        Restart = "on-failure";
      };
    };
  };
}
