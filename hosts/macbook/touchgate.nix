# The YubiKey's side of touchgate. The broker runs on dynhetz, and the
# pymux link from here asks this machine to sign each request and to
# unlock the broker. Each one opens a popup here and waits for a touch.
#
# Once, here:
#   ssh-keygen -t ed25519-sk -f ~/.ssh/id_ed25519_sk   # list the .pub in the
#                                                      # vault's touchgate-approvers
#   touchgate enroll                                   # seals the master password
{ pkgs, ... }:
{
  xdg.configFile."touchgate/config.toml".text = ''
    email = "bitwarden2@lillecarl.com"
    server = "eu"
    signing_key = "~/.ssh/id_ed25519_sk"
  '';

  xdg.configFile."pymux/plugins/touchgate.py".source = pkgs.touchgate.pymuxPlugin;
}
