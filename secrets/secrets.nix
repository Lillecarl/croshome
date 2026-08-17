# Who can decrypt what. Read by the `agenix` CLI, never by a module: the
# system side learns nothing from this file, it only decrypts whatever
# ../secrets/default.nix names in `age.secrets`.
#
# The CLI runs `import` on this file with no arguments, so it takes none.
# `RULES` defaults to ./secrets.nix, which means `agenix -e foo.age` works
# when you run it from this directory and nowhere else.
#
#   cd secrets
#   agenix -e wg0.key.age      # create or edit
#   agenix -r                  # re-encrypt every file after changing a key below
#
# Every secret needs two kinds of recipient, and leaving out either one breaks
# something:
#
#   * the user key, so you can still open the file to edit it
#   * the host key of every machine that reads the secret, so activation can
#     decrypt without a terminal
#
# Activation runs with no tty. A passphrase-protected identity is fine for the
# user entry and impossible for the host entry.
let
  # The age identity in ./identity.age, whose private half is in this
  # repository encrypted with a passphrase. This is the one that matters: it is
  # what ./unlock puts on a machine, so it is what activation decrypts with.
  #
  # Derived from the private half with `age-keygen -y`, so it is the public
  # half of exactly that file and not a key that happens to be nearby.
  lillecarl-age = "age1gpep8sqp2ze8kyl82tlt2mkh58e0x933a650al2x9uavj8gnmpdq8zqdmz";

  # ../lillecarl.pub, the same key hosts/hetztop/default.nix installs as an
  # authorized key. Kept as a second way in: it opens a secret from any machine
  # holding that ssh key, with no passphrase and no ./unlock.
  lillecarl = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPG9VIDuXFvf6BkqeCQxBDt3OxkdxF4nV0tdFuQUfVlz lillecarl@world";

  # Host keys, not user keys. agenix reads these at activation as root.
  #
  # macbook is /etc/ssh/ssh_host_ed25519_key.pub, read off the machine itself.
  # macOS generates it when Remote Login is first enabled, and this Mac has it.
  macbook = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA3g8vwXRMHonL65HEEzxJM0B7LiUMSRyJwYdKNNn16L";

  # hetztop comes from ~/.ssh/known_hosts for 65.108.150.98, not from the
  # machine. It is the key this Mac has accepted on every connection, so it is
  # right if no one has replaced the server. Confirm it on the host before you
  # trust a real secret to it:
  #
  #   ssh 65.108.150.98 cat /etc/ssh/ssh_host_ed25519_key.pub
  hetztop = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM84ek07rVn/Bj5dvmrhk96xpzbR+FUVu3ob8rmBV9VX";

  # cros is deliberately absent. ChromeOS runs home-manager with no system
  # underneath it, so it has no host key and no activation that runs as root.
  # A secret for that machine needs the home-manager module instead, which is
  # `${inputs.agenix}/modules/age-home.nix`.
in
{
  # No secrets yet. This is the shape:
  #
  #   "wg0.key.age".publicKeys = [ lillecarl-age lillecarl macbook ];
  #   "hetztop-api-token.age".publicKeys = [ lillecarl-age lillecarl hetztop ];
  #
  # Name a host here and in `age.secrets` in ./default.nix. Naming it in only
  # one of the two places is the usual mistake: this file decides who *can*
  # decrypt, that file decides what actually gets decrypted and where it lands.
  #
  # The attrset stays empty until then. Do not add a placeholder entry: `agenix
  # -r` walks `builtins.attrNames` of this file and would try to rekey it as a
  # real secret. The three bindings above are unused for now, which Nix does
  # not mind.
}
