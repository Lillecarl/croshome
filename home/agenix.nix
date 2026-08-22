# Home-manager agenix for secrets that must be a file while a user
# program runs. This is the counterpart to ../secrets/default.nix, which
# handles system-level secrets (decrypted to /run/agenix as root).
#
# Use this when a program reads a secret at runtime from a path that only
# the user should see, or on hosts with no system agenix at all (cros).
#
# Decrypted files land in $XDG_RUNTIME_DIR/agenix (Linux) or
# $(getconf DARWIN_USER_TEMP_DIR)/agenix (Darwin), under a generation
# symlink. See age-home.nix for the exact layout. The identity is the
# user's own SSH key at ~/.ssh/id_ed25519 (and id_rsa as fallback) --
# no passphrase, so decryption works on every login with no terminal.
# The file `../secrets/secrets.nix` still decides who *can* decrypt; this
# module decides what actually gets decrypted and where it lands, just like
# the system side.
{
  inputs,
  ...
}:
{
  imports = [ "${inputs.agenix}/modules/age-home.nix" ];

  # Keep the default identityPaths ( ~/.ssh/id_ed25519, ~/.ssh/id_rsa ).
  # Nothing to set unless a host uses a different key location.
  #
  # Individual secrets are declared where they are used, not here.
  # Example:
  #
  #   age.secrets.kagi-token.file = ../secrets/kagi-token.age;
  #
  # That file is then available at `config.age.secrets.kagi-token.path`,
  # which defaults to `$XDG_RUNTIME_DIR/agenix/kagi-token` (Linux) or the
  # Darwin equivalent. See ./kagi-mcp.nix for the live example.
}
