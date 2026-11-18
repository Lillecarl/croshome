{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.boot-guard;

  # systemd-boot sets this only while the booted entry still counts tries, so
  # a blessed entry never reboots here, however its checks fare.
  counted = "/sys/firmware/efi/efivars/LoaderBootCountPath-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f";
in
{
  options.services.boot-guard = {
    enable = lib.mkEnableOption ''
      a health gate for boot counting: a new boot is blessed only when the
      named units are up, and a boot still on trial that is not blessed by
      the deadline reboots, so systemd-boot can spend a try or fall back
    '';
    requiredServices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "sshd"
        "wireguard-wg-hetztop"
      ];
      description = ''
        Services, by `systemd.services` name, that must start before
        boot-complete.target. Name what a remote caller needs, not every
        unit: one that fails harmlessly on every boot would keep every new
        entry from being blessed.
      '';
    };
    deadline = lib.mkOption {
      type = lib.types.str;
      default = "10min";
      description = ''
        How long after the root file system takes over a boot on trial may
        take to reach boot-complete.target. Counted from stage 2, so time
        spent at the initrd's passphrase prompt does not count.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services =
      lib.genAttrs cfg.requiredServices (_: {
        requiredBy = [ "boot-complete.target" ];
        before = [ "boot-complete.target" ];
      })
      // {
        boot-guard-deadline = {
          description = "Reboot a boot on trial that was not blessed in time";
          serviceConfig.Type = "oneshot";
          path = [ config.systemd.package ];
          script = ''
            if systemctl is-active --quiet boot-complete.target; then
              exit 0
            fi
            if [ ! -e ${counted} ]; then
              echo "boot-complete.target is not reached, but this entry is not on trial; not rebooting"
              exit 0
            fi
            echo "boot-complete.target is not reached after ${cfg.deadline} on an entry on trial; rebooting"
            systemctl reboot
          '';
        };
      };

    systemd.timers.boot-guard-deadline = {
      wantedBy = [ "timers.target" ];
      timerConfig.OnActiveSec = cfg.deadline;
    };
  };
}
