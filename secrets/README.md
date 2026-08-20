# Secrets

agenix, with one age identity that lives in this repository in encrypted form.
There is no key file to keep anywhere else and nothing to copy between
machines.

Two things read a secret, and they read it in different ways:

| Who | Identity it uses | Passphrase |
| --- | --- | --- |
| You, editing | `./identity.age` directly | Yes, every time |
| Activation | `/var/lib/agenix/identity` | No, and it cannot |

Activation has no terminal. That is the whole reason the plaintext copy at
`/var/lib/agenix/identity` exists, and the reason `./unlock` puts it there.

The two OpenPGP keys are a third case and read neither row: nothing decrypts
them without a person. See [OpenPGP](#openpgp) below.

## One time, to create the identity

Do this once, ever. It creates the key that every secret is encrypted to.

**1. Generate the identity.**

```sh
cd secrets
age-keygen -o identity.txt          # prints the public key -- keep it
```

**2. Encrypt it at work factor 21.**

`age -p` would use work factor 18, and the CLI has no flag to raise it. The
`age-plugin-batchpass` plugin does, through `AGE_PASSPHRASE_WORK_FACTOR`, and
it ships in the same `age` package.

```sh
read -s pw                          # typed, so it stays out of shell history
AGE_PASSPHRASE_FD=3 AGE_PASSPHRASE_WORK_FACTOR=21 \
  age -e -j batchpass -a -o identity.age identity.txt 3< <(printf '%s' "$pw")
set -e pw                           # fish; `unset pw` in bash
```

Use fd 3, not fd 0: the plugin speaks its own protocol over stdin, and
`AGE_PASSPHRASE_FD=0` deadlocks.

Measured on an M5 Pro: **2.01 GiB peak memory, 3.1 s to encrypt, 2.6 s to
decrypt**. Memory is what makes this expensive to attack, not time. A 24 GB GPU
fits about 12 guesses at once at this size, against tens of thousands for a
KDF that is merely slow.

Nothing special is needed to *decrypt* it. Stock `age` accepts work factors up
to 22 by default (`maxWorkFactor: 22` in `scrypt.go`), so 21 is under the cap
and no plugin, flag or environment variable is involved when unlocking.

A passphrase still matters more than the work factor. Going 18 to 21 buys three
bits; one more Diceware word buys nearly thirteen. Do both.

**3. Check it decrypts before you delete anything.**

```sh
age -d identity.age | head -2     # asks for the passphrase
```

`age-keygen` writes three lines -- `# created:`, `# public key:`, then the
secret -- so `head -2` shows the first two and stops before the key itself.
The public key should match what `./secrets.nix` records. That proves the
passphrase works *and* that the file holds the right key.

The `# created:` line is a second check: it equals line 1 of `identity.txt`
while that file still exists, which confirms the two are the same key without
comparing anything secret.

No `-i` here, and the distinction is easy to get wrong. `identity.age` is
**passphrase**-encrypted, so age wants the passphrase and nothing else; adding
`-i` makes it refuse:

```
age: error: file is passphrase-encrypted but identities were specified with -i/--identity
```

`-i identity.age` is right in the *other* direction -- when opening a secret
that was encrypted to this identity's public key, as in `agenix -e foo.age -i
identity.age` below. Same file, two roles: the thing being decrypted, and the
key doing the decrypting.

Pipe it. Unpiped, this prints the private key to your terminal.

**4. Delete the plaintext.**

```sh
rm identity.txt
```

Not `rm -P` and not `shred`. `rm` here is GNU coreutils, which has no `-P`, and
this disk is APFS -- copy-on-write, so an overwrite writes new blocks and
leaves the old ones. FileVault is what actually protects the remains, and the
file was short-lived. Do not reach for a tool that only feels safer.

`.gitignore` already covers `identity.txt`, so a slip does not become a commit.
Only `identity.age` is committed.

**5. Add the public key to `./secrets.nix`.**

Paste what `age-keygen` printed:

```nix
lillecarl-age = "age1...";
```

If you lost it, derive it again from the private half:

```sh
age-keygen -y identity.txt
```

It replaces nothing. The ssh key stays, and so do the host keys. Put
`lillecarl-age` first on every secret, since that is the identity `./unlock`
installs and therefore the one activation uses.

## Once per machine

```sh
./secrets/unlock
```

It asks for the passphrase and writes `/var/lib/agenix/identity`, root-owned
and 0600. Run it **before** the first activation that has a secret to decrypt.
The file survives reboots, which is what lets the boot-time activation work
without you.

```sh
./secrets/unlock --status    # is it in place
./secrets/unlock --lock      # remove it
```

The script needs only bash. If the machine has no `age` yet, it runs one from
nixpkgs -- that is the case it exists for.

## Adding a secret

Three steps, and all three are required.

```sh
# 1. name the file and who may decrypt it
$EDITOR secrets/secrets.nix
#   "foo.age".publicKeys = [ lillecarl macbook ];

# 2. create it, using the encrypted identity directly
cd secrets && agenix -e foo.age -i identity.age

# 3. tell the host to decrypt it -- in the *host's* file, not this one
$EDITOR hosts/macbook/default.nix
#   age.secrets.foo.file = ../../secrets/foo.age;
```

Step 1 decides who *can* decrypt. Step 3 decides what actually gets decrypted
and where it lands. Doing one without the other is the usual way to lose an
hour.

Step 3 goes in `./default.nix` only when **both** system hosts read the same
secret. Both `hosts/macbook` and `hosts/hetztop` import `../../secrets`, so an
`age.secrets` entry there is an entry on both -- the other host then decrypts
and places a file it has no use for on every activation, and pulls in the whole
ramdisk and daemon apparatus that `mkIf (cfg.secrets != { })` otherwise spares
it. A secret one host reads belongs in that host's file. `./default.nix` keeps
an index of which file owns what.

`-i identity.age` in step 2 is deliberate: age accepts a passphrase-encrypted
file as an identity and prompts for the passphrase. Editing therefore needs no
plaintext key anywhere, and `/var/lib/agenix/identity` is not involved.

After changing who may decrypt anything, re-encrypt everything:

```sh
cd secrets && agenix -r -i identity.age
```

`agenix` here is `pkgs.agenix`, defined in `../pkgs/default.nix`. On a machine
this configuration has never activated it is still one command away, and no
`age`, `agenix` or nix profile install is needed:

```sh
nix run --file . pkgs.agenix -- -e foo.age -i secrets/identity.age
```

## Creating a secret without an editor

An agenix `.age` file is an ordinary age file encrypted to the recipients that
`./secrets.nix` lists for it. Nothing about the format comes from agenix, so a
file written with plain `age -r` is read by `agenix -d`, rekeyed by `agenix -r`,
and decrypted at activation like any other.

That matters when the plaintext already exists and should not be routed through
an editor and a temporary directory -- lifting a key off a machine being
decommissioned, most of all:

```sh
sudo cat /etc/wireguard/dc1.key |
  nix run --file . pkgs.age -- \
    -r "age1gpep8sqp2ze8kyl82tlt2mkh58e0x933a650al2x9uavj8gnmpdq8zqdmz" \
    -r "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA3g8vwXRMHonL65HEEzxJM0B7LiUMSRyJwYdKNNn16L" \
    -a -o secrets/wg-dc1.key.age
```

The plaintext exists only in the pipe: no `mktemp -d` to trust the cleanup of,
no editor and so no swap or undo files, and nothing to remember to delete.

Two things have to agree with `./secrets.nix`, or the next `agenix -r` silently
rewrites the file:

- **the recipient list**, exactly -- order does not matter, membership does
- **`-a`**, which must match `armor = true` on that secret's rule. agenix omits
  `--armor` unless the rule sets it, so an armoured file under a rule without
  the attribute is rewritten as binary.

Then verify it before trusting it, especially if the source machine is about to
be wiped -- an unreadable file is not discovered later, it is discovered never:

```sh
cd secrets && agenix -d wg-dc1.key.age -i identity.age | wg pubkey
```

That asks for the passphrase, and its output should equal the public key the
live interface reports (`sudo wg show dc1 public-key`). Comparing public halves
proves the right key is inside without putting the private one on a terminal.

## Authoring a secret on a machine you will then destroy

This needs no `./unlock`, and you should not run it there. `unlock` writes the
plaintext identity to `/var/lib/agenix/identity` and leaves it. On a machine
about to be decommissioned that is the one thing to avoid.

Editing uses the encrypted identity directly and writes no key to disk:

```sh
git clone https://github.com/Lillecarl/croshome
cd croshome/secrets

# no agenix or age installed? neither is needed on the machine itself
nix run --file . pkgs.agenix -- -e secrets/wg0.age -i secrets/identity.age
```

`--file .` and not `github:ryantm/agenix`: this repository pins the version and
builds it against its own package set, so the CLI matches the module that will
decrypt the file. It also works with no network beyond what the lock already
names.

If the plaintext is already on the machine -- which is the usual case here --
skip the editor entirely and use the `age -r` form above. It is fewer moving
parts precisely where the machine is about to be destroyed.

You are asked for the passphrase, you edit the cleartext in `$EDITOR`, and
agenix re-encrypts. Then add the entry to `./secrets.nix`, commit and push.

Before you wipe the machine, know what touched a disk:

- agenix decrypts into `mktemp -d` and removes it with `trap cleanup 0 2 3 15`.
  That covers exit, interrupt, quit and terminate. It does **not** cover
  `SIGKILL` or power loss, and it unlinks rather than overwrites.
- `$EDITOR` leftovers are the likelier leak: vim swap and undo files, editor
  backups, `.orig` files. Check for them.
- Do not paste a key on a command line. Shell history outlives the session.
- The clone contains `identity.age`, which is encrypted and safe to leave.

If you did run `./unlock` there, `./secrets/unlock --lock` removes the
plaintext before you hand the machine on.

## OpenPGP

Two keys, one per identity, and they follow the same split the commit author
already does:

| Name | User IDs | Signs |
| --- | --- | --- |
| `pgp-work` | Carl Andersson <carl.andersson@dynamist.se> | everything else |
| `pgp-personal` | lillecarl <prettygood@lillecarl.com><br>lillecarl <git@lillecarl.com> | this repository |

The personal key carries two addresses, and the second one is not decoration.
GitHub and GitLab badge a signature only when the address on the **commit** is
one of the key's user IDs. `../home/vcs.nix` commits as `git@lillecarl.com`
here, so a key naming only `prettygood@lillecarl.com` gives signatures that are
valid and shown as unverified -- the one thing publishing a key is meant to
fix. GitHub settled it: it reports `git@lillecarl.com` as a verified address on
the account and `prettygood@lillecarl.com` as not.

The rule generalises. Before adding an address to `./pgp-create`, check that
whatever commits under it is a user ID on the key that signs it.

Each key is an ed25519 primary that only certifies, with an ed25519 signing
subkey and a cv25519 encryption subkey under it. The primary is the identity
and rarely has to move. A subkey does the daily work and can be replaced
without changing who you are.

`../home/gpg.nix` installs gpg and its agent. `../home/vcs.nix` turns signing
on, and reads the fingerprints from `./pgp-keys.nix`.

### One time, to create the keys

Once, ever, on one machine. It must be a terminal: it asks for a passphrase.

```sh
./secrets/pgp-create
```

It makes both keys, encrypts each secret key to `lillecarl-age`, writes the
public halves and `./pgp-keys.nix`, imports both into that machine's GnuPG,
and then proves both age files decrypt before it says it is done.

Commit what it wrote, rebuild, and signing turns on.

### Once per machine

```sh
./secrets/pgp-import            # both keys
./secrets/pgp-import personal   # or just one
./secrets/pgp-import --status   # what is here already
```

It asks for the age passphrase, decrypts, and imports. GnuPG keeps the key
afterwards, so nothing runs again at boot or at login.

`--status` needs no passphrase, no key and no gpg. Run it first when signing
stops working.

### Why there is no agenix home-manager module here

The obvious design is `${inputs.agenix}/modules/age-home.nix`, a user-level
agenix that decrypts into `$XDG_RUNTIME_DIR`. It is the wrong shape for this,
and the reason is worth keeping.

That module exists for a secret that has to **be a file** while a program
runs. So it decrypts on every login, with no terminal, which means it needs an
identity the user can read with no passphrase. Setting that up would mean a
second plaintext copy of the age key, this time user-readable.

An OpenPGP key is not that shape. It goes into GnuPG's own store **once** and
stays there across reboots. So the decryption is a thing a person does, one
command per machine, and it can ask for the passphrase like any other. The
identity at `/var/lib/agenix/identity` stays root-only, and the system agenix
in `./default.nix` stays the only agenix in this repository.

Reach for the home module when a secret must be a file at runtime -- an API
token some program reads at startup. Not for this.

### Two passphrases, and both must survive

The key's own passphrase protects the export before age ever sees it. The age
passphrase protects it again in this public repository. That is deliberate:
the ciphertext here is world-readable and permanent, so one secret should not
be the whole of its protection.

The cost is that losing **either** loses the key. Put both in a password
manager. A third weak recipient is not the fix -- see the note on `lillecarl`
in `./secrets.nix`.

`../home/gpg.nix` sets the agent cache to 400 days for exactly this reason,
which is "until the agent stops" in practice. hetztop is a server with agents
committing on it around the clock, and a cache that lapses overnight means a
signing failure at an hour when nobody is there to type anything. Read the
comment there for what that trades away.

So one command per boot, and `pgp-unlock` is it:

```sh
pgp-unlock            # both keys, one prompt
pgp-unlock --status   # what the agent holds
pgp-unlock --lock     # forget it again
```

One prompt covers both keys because gpg-agent caches per subkey, not per
passphrase: unlocking one leaves the other locked, and a commit in a
repository that signs with the other key still stops to ask. Until it has run,
jj cannot even snapshot -- signing failure, not just an unsigned commit.

### Renewal, revocation and publishing

Both keys expire two years after `./pgp-create` ran. Renewal does not change
the fingerprint, so nothing downstream moves:

```sh
gpg --quick-set-expire <fingerprint> 2y '*'      # '*' covers the subkeys too
```

Then re-export, because `./pgp-work.age` still holds the old expiry:

```sh
cd secrets
gpg --export-secret-keys --armor <fingerprint> |
  age -r "$(sed -n 's/^ *lillecarl-age = "\(age1[^"]*\)".*/\1/p' secrets.nix)" \
      -a -o pgp-work.age
```

`./pgp-create` copied the revocation certificate gpg made at generation to
`~/.gnupg/openpgp-revocs.d/<fingerprint>.rev` on that one machine. It is not in
this repository, and it should not be: whoever holds it can revoke the key.
It is the only way to retire a key whose passphrase is lost, so back it up
somewhere you trust. With the key and its passphrase in hand you can always
make another with `gpg --gen-revoke`.

The public halves are checked in as `./pgp-work.pub.asc` and
`./pgp-personal.pub.asc`, in plaintext, because a public key is public. Hand
one to somebody directly, or publish it:

```sh
gpg --send-keys <fingerprint>     # keys.openpgp.org, per ../home/gpg.nix
```

keys.openpgp.org verifies the address before it serves a user ID. The old SKS
pool served whatever anyone uploaded, which is how keys got poisoned with
thousands of bogus signatures.

Both keys are already on GitHub (`Lillecarl`) and on gitlab.com (`lillecarl`),
added 2026-08-20. Neither host stores anything secret, so re-uploading after a
renewal is safe and is the way to update them -- the fingerprint does not
change, but the expiry date on the uploaded copy does.

`glab` and `gh` both need a token for that. `ask` and `answer`, from
`../home/ask.nix`, are how an agent supplies one without it passing through a
conversation.

## Notes

- **agenix discards `$EDITOR` when stdin is not a tty.** `pkgs/agenix.sh` has
  `[ -t 0 ] || EDITOR='cp -- /dev/stdin'`, unconditionally and on every
  platform. So `EDITOR='cp somefile' agenix -e foo.age` does what it says
  interactively and something else entirely from a script or an agent's shell:
  the override wins and agenix reads the secret from stdin instead. Do not set
  `EDITOR` to load a file non-interactively -- use the `age -r` form under
  "Creating a secret without an editor" below, which has no such surprise.
- Piping a secret in does not work on macOS: the `cp -- /dev/stdin` that the
  override installs is BSD `cp` there, which refuses it. Interactively it is
  fine; this only bites scripts.
- The `hetztop` host key in `./secrets.nix` came from `known_hosts`, not from
  the machine. Confirm it before trusting a real secret to that host:
  `ssh 65.108.150.98 cat /etc/ssh/ssh_host_ed25519_key.pub`
- cros gets nothing here. It runs home-manager with no system underneath, so
  it has no host key and no activation that runs as root. That machine needs
  `${inputs.agenix}/modules/age-home.nix` instead.
