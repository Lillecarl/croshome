# The fingerprints of the two OpenPGP keys in this directory.
#
# Derived data, not a choice. `./pgp-create` writes this file after it makes
# the keys, so nobody transcribes forty hex characters by hand and nobody has
# to keep two copies in step.
#
# It is committed because ../home/gpg.nix and ../home/vcs.nix read it at
# evaluation time, so a fresh clone has to find it. Nothing secret is here: a
# fingerprint is the public name of a key.
#
# `null` means the key does not exist yet. Signing stays off while either one
# is null -- see ../home/vcs.nix -- so this file is safe to evaluate before
# `./pgp-create` has ever run.
{
  # Carl Andersson <carl.andersson@dynamist.se>
  work = null;

  # lillecarl <prettygood@lillecarl.com>
  personal = null;
}
