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

**4. Add the public key to `./secrets.nix`.**

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

# 3. tell the host to decrypt it
$EDITOR secrets/default.nix
#   age.secrets.foo.file = ./foo.age;
```

Step 1 decides who *can* decrypt. Step 3 decides what actually gets decrypted
and where it lands. Doing one without the other is the usual way to lose an
hour.

`-i identity.age` in step 2 is deliberate: age accepts a passphrase-encrypted
file as an identity and prompts for the passphrase. Editing therefore needs no
plaintext key anywhere, and `/var/lib/agenix/identity` is not involved.

After changing who may decrypt anything, re-encrypt everything:

```sh
cd secrets && agenix -r -i identity.age
```

## Authoring a secret on a machine you will then destroy

This needs no `./unlock`, and you should not run it there. `unlock` writes the
plaintext identity to `/var/lib/agenix/identity` and leaves it. On a machine
about to be decommissioned that is the one thing to avoid.

Editing uses the encrypted identity directly and writes no key to disk:

```sh
git clone https://github.com/Lillecarl/croshome
cd croshome/secrets

# no agenix or age installed? neither is needed on the machine itself
nix run github:ryantm/agenix -- -e wg0.age -i identity.age
```

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

## Notes

- Piping a secret in does not work on macOS. agenix replaces `$EDITOR` with
  `cp -- /dev/stdin` when stdin is not a tty, and GNU `cp` then refuses the
  pipe. Interactively it is fine; this only bites scripts.
- The `hetztop` host key in `./secrets.nix` came from `known_hosts`, not from
  the machine. Confirm it before trusting a real secret to that host:
  `ssh 65.108.150.98 cat /etc/ssh/ssh_host_ed25519_key.pub`
- cros gets nothing here. It runs home-manager with no system underneath, so
  it has no host key and no activation that runs as root. That machine needs
  `${inputs.agenix}/modules/age-home.nix` instead.
