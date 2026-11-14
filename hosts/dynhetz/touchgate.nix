# touchgate's broker: it holds the Bitwarden vault in memory and releases a
# secret to one command once a security key signs the request. The vault
# here is the lab account (EU cloud), which holds no real secret.
#
# The YubiKey is on the Mac (../macbook/touchgate.nix). With no
# `signing_key` here, a request waits for the Mac: the pymux plugin asks
# the Mac's pymux, over the link it holds to this one, to sign it and to
# unlock the broker. Each takes a touch there.
{ lib, pkgs, ... }:
{
  xdg.configFile."touchgate/config.toml".text = ''
    email = "bitwarden2@lillecarl.com"
    server = "eu"
  '';

  # Follows the broker: a popup in the requesting pane's session, and the
  # questions to the Mac. One file, loaded as a pymux file plugin.
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
