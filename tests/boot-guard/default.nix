/*
  boot-guard and ai-reboot on vivarium's firmware boot (OVMF and
  systemd-boot with boot counting).

  `good` and `bad` differ from the booted system by one file each. In
  `bad` the probe that boot-guard requires fails, so its entry is never
  blessed, and boot-guard's deadline reboots it: the host only waits.

  No TPM or LUKS here (nixidae/nixidae#1502), so ai-reboot's check is
  pointed at a device that is not LUKS, which it must refuse.
*/
{ mkTest }:
mkTest (
  { systems, ... }:
  let
    next =
      name: extra:
      "${(systems.one.extendModules {
        modules = [
          { environment.etc."boot-guard-generation".text = "${name}\n"; }
          extra
        ];
      }).config.system.build.toplevel
      }";
  in
  {
    name = "boot-guard";
    backend = "qemu";
    phases.test = {
      script = ../boot-guard.py;
      after = [ "boot" ];
    };
    nodes.one =
      { settings, lib, ... }:
      {
        imports = [
          ../../modules/nixos/ai-reboot.nix
          ../../modules/nixos/boot-guard.nix
        ];
        vivarium.lateClosure = [
          settings.good
          settings.bad
        ];
        vivarium.efi = true;
        boot.loader.systemd-boot.bootCounting = {
          enable = true;
          tries = 2;
        };

        systemd.services.boot-guard-probe = {
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = lib.mkDefault "true";
        };
        services.boot-guard = {
          enable = true;
          requiredServices = [ "boot-guard-probe" ];
          deadline = "20s";
        };

        users.users.alice = {
          isNormalUser = true;
          uid = 1000;
        };
        programs.ai-reboot = {
          enable = true;
          sudo.users = [ "alice" ];
          tpm2Devices = [ "/dev/vda" ];
        };
      };
    settings = {
      good = next "good" { };
      bad = next "bad" { systemd.services.boot-guard-probe.script = "exit 1"; };
    };
  }
)
