{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.ai-reboot;

  # polkit refuses a reboot from an SSH session, which logind counts as
  # inactive, so a remote caller needs this rule. The check before the reboot
  # is what makes it safe to hand out: a machine whose disk would wait at the
  # passphrase prompt is refused unless the caller says so.
  ai-reboot = pkgs.writeShellApplication {
    name = "ai-reboot";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.cryptsetup
      pkgs.jq
      config.systemd.package
    ];
    text = ''
      check=1
      case "''${1:-}" in
        "") ;;
        --no-tpm-check) check=0 ;;
        *)
          echo "usage: ai-reboot [--no-tpm-check]" >&2
          exit 2
          ;;
      esac

      if [ "$(id -u)" -ne 0 ]; then
        # The setuid wrapper by path: only it elevates, and a caller such as
        # systemd-run may hand over a PATH without /run/wrappers/bin.
        exec /run/wrappers/bin/sudo -n /run/current-system/sw/bin/ai-reboot "$@"
      fi

      devices=(${lib.escapeShellArgs cfg.tpm2Devices})
      if [ "$check" -eq 1 ]; then
        for device in "''${devices[@]}"; do
          if ! cryptsetup luksDump --dump-json-metadata "$device" \
            | jq -e 'any(.tokens[]; .type == "systemd-tpm2")' >/dev/null; then
            echo "ai-reboot: $device has no systemd-tpm2 token, so the next boot waits for a passphrase." >&2
            echo "ai-reboot: --no-tpm-check reboots anyway." >&2
            exit 1
          fi
        done
      fi

      systemctl reboot
    '';
  };
in
{
  options.programs.ai-reboot = {
    enable = lib.mkEnableOption "ai-reboot, a reboot that a remote caller may run without a password";
    tpm2Devices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "/dev/disk/by-id/md-name-any:root-part1" ];
      description = ''
        LUKS devices the next boot unlocks from the TPM. ai-reboot refuses to
        reboot while one of them has no systemd-tpm2 token.
      '';
    };
    sudo = {
      users = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Users that may run ai-reboot without a password.";
      };
      groups = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Groups that may run ai-reboot without a password.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ ai-reboot ];

    # The stable path: sudo matches the command as the caller wrote it, and
    # ai-reboot re-executes itself by this path.
    security.sudo.extraRules = [
      {
        users = cfg.sudo.users;
        groups = cfg.sudo.groups;
        commands = [
          {
            command = "/run/current-system/sw/bin/ai-reboot";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];
  };
}
