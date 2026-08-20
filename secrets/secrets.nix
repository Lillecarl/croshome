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
  #
  # Do not add it to a secret without thinking. It has no passphrase and has
  # been reused widely, so it is a poor recipient however convenient: anything
  # encrypted to it is only as protected as the most careless place that key
  # has ever been copied to. "wg-dc1.key.age" below leaves it out for exactly
  # this reason.
  #
  # Its private half is also unaccounted for. It is not `~/.ssh/id_ed25519` on
  # `nub` (checked while lifting the WireGuard key off that machine), and the
  # Mac's is AAAAC3...IF4AwtWUz3usygb2J6owsUJs4X2yTchIGZyI+VDE76tF per
  # ../hosts/macbook/default.nix, which is also not this -- a search of that
  # machine's $HOME and ssh-agent came up empty. hetztop authorises it, so it
  # is in use somewhere; cros is the remaining candidate and has not been
  # checked. Treat it as unverified until it has been.
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
  # The WireGuard private key for the `dc1` tunnel into the Dynamist network --
  # 10.0.250.129/24, peer 155.4.106.42:51820. Lifted off `nub`, a NixOS laptop
  # that held it at /etc/wireguard/dc1.key and is being decommissioned.
  #
  # It is here because the key is not reissuable on demand: getting a new one
  # deployed goes through a process worth avoiding, so the key outlives the
  # machine rather than being rotated with it. That is also why it is encrypted
  # to every identity below that can hold one, and not only to the machine that
  # wants it today.
  #
  # The rest of the tunnel, recorded here because `nub` is the only place it
  # exists and that machine is being wiped. None of it is secret, and all of it
  # is needed to stand the tunnel up again -- a key with no routing table is
  # half a rescue. Read off `networking.wireguard.interfaces.dc1` in the private
  # repo ~/Dynamist/nixos/new/nub/wireguard.nix:
  #
  #   address                10.0.250.129/24
  #   peer public key        3dPS9vn68QIXobuU8HG7u/GlUlY0Hjs3LbH6jeq0wUc=
  #   endpoint               155.4.106.42:51820
  #   persistentKeepalive    30
  #   postSetup              resolvectl dns dc1 10.0.250.1
  #                          resolvectl domain dc1 "dynami.st"
  #   allowedIPs             10.0.250.1/32   10.0.4.0/24    10.0.5.0/24
  #                          10.0.10.0/24    10.0.90.0/24   10.0.100.0/24
  #                          100.64.0.0/22   10.240.0.0/16  10.7.10.0/24
  #                          10.7.0.0/24     10.7.5.0/24    10.0.95.0/24
  #
  # Twelve ranges, not the single /24 the address suggests. Copy them; do not
  # infer them. A short list does not fail loudly -- the tunnel comes up and
  # some subnet of the office is quietly unreachable.
  #
  # macOS has no in-kernel WireGuard, so whatever consumes this on the Mac runs
  # wireguard-go in userspace over utun. Expect it to be slower than nub was;
  # that is the platform, not a broken tunnel.
  #
  # `nub` itself is not a recipient and never will be. It has no ssh host key
  # at all -- the machine never ran sshd -- so there was nothing to encrypt to,
  # and it is going away regardless. The key was read off its disk once, by
  # hand, and encrypted here.
  #
  # hetztop is deliberately *not* a recipient, though it is the one entry here
  # that could have been added for free. It is a public-internet VPS, so making
  # its host key open this would mean that taking that box yields a live
  # credential into the office network -- for a secret it has no `age.secrets`
  # entry for and never reads. Worse, its key below is the unverified one, taken
  # from known_hosts rather than from the machine. Adding it later is one
  # `agenix -r`; un-exposing a key someone already holds is not possible.
  #
  # cros is absent for the reason given above: no host key, no root activation.
  # It would need `${inputs.agenix}/modules/age-home.nix` and a fourth identity.
  #
  # `lillecarl` is not a recipient either, and that one was a deliberate
  # subtraction rather than an omission. It is an ssh key with no passphrase
  # that has been copied to many places over the years, so encrypting to it
  # would set the floor for this secret at "whoever has ever held that key" --
  # which is exactly the property `lillecarl-age` exists to provide and would
  # have been quietly cancelled by listing both.
  #
  # That leaves two readers, and it is worth being honest about which:
  # `lillecarl-age`, whose passphrase has to still be known, and this Mac's
  # host key, which does not survive the machine or a disk swap. The passphrase
  # is therefore the thing that must not be lost -- a password manager, not a
  # third weak recipient, is the fix for that.
  #
  # `armor` keeps this ASCII rather than binary, so it diffs in git and can be
  # eyeballed. It has to agree with how the file was first written -- this one
  # was created with `age -a` outside agenix (see ./README.md), and dropping
  # this attribute would make the next `agenix -r` silently rewrite it as
  # binary.
  "wg-dc1.key.age" = {
    publicKeys = [
      lillecarl-age
      macbook
    ];
    armor = true;
  };

  # The two OpenPGP secret keys, exported with `gpg --export-secret-keys`.
  # `pgp-work` is Carl Andersson <carl.andersson@dynamist.se> and
  # `pgp-personal` is lillecarl <prettygood@lillecarl.com>. ./pgp-create makes
  # them, ./pgp-import puts one into GnuPG on a machine, and ./pgp-keys.nix
  # records the fingerprints for ../home/vcs.nix to sign with.
  #
  # `lillecarl-age` is the only recipient, and the two omissions are deliberate.
  #
  # No host key. A host key is for a secret that activation decrypts with no
  # terminal, and nothing decrypts these without a person: ./pgp-import is a
  # command you run once per machine, and GnuPG keeps the key afterwards. So
  # listing hetztop would mean that taking a public VPS yields a work identity,
  # in exchange for nothing.
  #
  # Not `lillecarl` either, for the reason given above it: a passphrase-less
  # ssh key that has been copied to many places sets the floor for anything
  # encrypted to it.
  #
  # These files are less exposed than the rest of this directory, and it is
  # worth being exact about why. The export is already encrypted with the key's
  # own passphrase before age ever sees it, so the ciphertext in this public
  # repository is behind two independent secrets. Both have to be broken, and
  # both have to survive: lose either passphrase and the key is gone with it.
  # Put both in a password manager.
  #
  # `armor` because ./pgp-create writes them with `age -a`. It has to agree, or
  # the next `agenix -r` silently rewrites them as binary.
  "pgp-work.age" = {
    publicKeys = [ lillecarl-age ];
    armor = true;
  };

  "pgp-personal.age" = {
    publicKeys = [ lillecarl-age ];
    armor = true;
  };

  # Adding another: name it here and in `age.secrets` in ./default.nix. Naming
  # it in only one of the two places is the usual mistake -- this file decides
  # who *can* decrypt, that file decides what actually gets decrypted and where
  # it lands.
  #
  #   "hetztop-api-token.age".publicKeys = [ lillecarl-age lillecarl hetztop ];
  #
  # Do not add a placeholder entry: `agenix -r` walks `builtins.attrNames` of
  # this file and would try to rekey it as a real secret.
}
