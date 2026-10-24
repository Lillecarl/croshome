# The secrets hetztop's hosting stack reads, and no others.
#
# They live here rather than in ../../secrets/default.nix because that file is
# imported by every NixOS host: an entry there is an entry dynhetz declares,
# decrypts and keeps in /run for nothing. See that file's comment on the same
# split.
#
# Every one of these is read at system level, so each is encrypted to the host
# key as well as to lillecarl-age: activation has no terminal and cannot answer
# a passphrase. Adding one means naming it here, in ./secrets.nix under
# ../../secrets for its recipients, and -- if a build reads it -- wherever it is
# used.
{ ... }:
{
  # bcrypt hash of the login password dex checks, no trailing newline.
  # Re-encrypt this file and restart dex to change the password.
  age.secrets.dex-password-hash = {
    file = ../../secrets/dex-password-hash.age;
  };

  # The OAuth2 client secret the first app and dex share: dex reads it to
  # accept the login, the app's gate reads it to redeem that login.
  age.secrets.dex-client-app = {
    file = ../../secrets/dex-client-app.age;
  };

  # The key every gate on this host encrypts its session cookie with.
  age.secrets.gate-cookie-secret = {
    file = ../../secrets/gate-cookie-secret.age;
  };

  # Declared in ./postgres.nix, which is where the role that uses it is.
}
