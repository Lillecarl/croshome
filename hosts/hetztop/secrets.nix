# The secrets hetztop's hosting stack reads, from
# ../../secrets/sops/hosts/hetztop.yaml. heycarl's are in ./heycarl.nix and
# the app role's password in ./postgres.nix, beside what reads them.
{
  # bcrypt hash of the login password dex checks, no trailing newline, cost 10
  # or more (`mkpasswd -m bcrypt -R 12`; its default is 5). dex reads it only
  # at start.
  sops.secrets.dex-password-hash.restartUnits = [ "dex.service" ];

  # The OAuth2 client secret the first app and dex share: dex reads it to
  # accept the login, the app's gate reads it to redeem that login.
  sops.secrets.dex-client-app = { };

  # The key every gate on this host encrypts its session cookie with.
  sops.secrets.gate-cookie-secret = { };
}
