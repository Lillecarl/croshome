# touchgate's broker: it holds the Bitwarden vault in memory and releases a
# secret to one command once a security key signs the request. The vault
# here is the lab account (EU cloud), which holds no real secret.
#
# Unlock from the Mac with the YubiKey:
#   touchgate enroll                      # once, two touches
#   ssh -N -L /tmp/touchgate.sock:/run/user/1000/touchgate/broker.sock dynhetz &
#   TOUCHGATE_SOCKET=/tmp/touchgate.sock touchgate unlock --yubikey
{ lib, pkgs, ... }:
{
  xdg.configFile."touchgate/config.toml".text = ''
    email = "bitwarden2@lillecarl.com"
    server = "eu"
    # The ed25519-sk key's public half; the private half is in the agent
    # forwarded from the Mac.
    signing_key = "~/.ssh/id_ed25519_sk.pub"
  '';

  # A popup in the requesting pane's session showing the request as the
  # broker holds it. One file, loaded as a pymux file plugin.
  xdg.configFile."pymux/plugins/touchgate.py".source = pkgs.touchgate.pymuxPlugin;

  systemd.user.services.touchgate-broker = {
    Unit.Description = "touchgate broker: the Bitwarden vault, released per command for a security key touch";
    Service = {
      ExecStart = "${lib.getExe pkgs.touchgate} broker";
      Restart = "on-failure";
    };
    Install.WantedBy = [ "default.target" ];
  };
}
