# Secrets

sops-nix. The secrets are YAML files in `./sops`, and each value in them is
encrypted. Every file is encrypted to the admin keys and to the hosts that
read it.

| Who | Key | Passphrase |
| --- | --- | --- |
| You, editing | the master key, `./identity.age` | once per boot |
| You, on a machine with a TPM | a TPM-held admin key | never |
| A host, at activation | its ssh host key, `/etc/ssh/ssh_host_ed25519_key` | never |

No host holds the master key. A taken host gives away that host's secrets
only.

`secrets` is the tool for all of it. It is on the PATH of every host. On a
machine this configuration has never built:

```sh
nix run --file . pkgs.croshome-secrets -- --help
```

## Files

| File | Read by |
| --- | --- |
| `sops/hosts/<host>.yaml` | that host |
| `sops/user.yaml` | the hosts listed for it, decrypted for your user |
| `sops/dc1.yaml` | dynhetz and macbook (the dc1 WireGuard key) |
| `sops/admin.yaml` | admins only: OpenPGP keys, pre-made host keys |
| `sops/keys.json` | not a secret: every admin and host key, and who reads what |
| `sops/.sops.yaml` | made from `keys.json` by `secrets sync`; do not edit |

## A new machine, before its first install

Use this when nixos-anywhere or a manual install will create the machine. The
host key exists before the machine does, so its secrets decrypt on the first
boot.

```sh
secrets host add newbox --generate --file user.yaml
secrets host install-files newbox /tmp/newbox
nixos-anywhere --extra-files /tmp/newbox --flake ... root@<address>
rm -rf /tmp/newbox
```

1. `host add --generate` makes an ed25519 host key and stores it in
   `admin.yaml` under `host-keys.newbox`. It adds the host to `keys.json`
   (and to each `--file`), then re-encrypts everything.
2. `host install-files` writes the key to `DIR/etc/ssh/`, mode 0600, for
   `--extra-files`. Delete the directory after the install.
3. Add the host to `default.nix` and give it `croshome.secrets.enable`. Every
   NixOS host gets that from `profiles/nixos/base.nix`.

Commit `keys.json`, `.sops.yaml` and the changed YAML files.

## A machine that already runs

```sh
secrets host add newbox --ssh root@newbox --file user.yaml
```

This reads `/etc/ssh/ssh_host_ed25519_key.pub` over ssh. The JSON it prints
holds the key's fingerprint. Compare it with `ssh-keygen -lf
/etc/ssh/ssh_host_ed25519_key.pub` on the machine when ssh has not seen the
host before. Then rebuild that machine.

`--recipient age1...` adds a key that you already have. A host that is
missing from `keys.json` fails its build, and the message gives these
commands.

To retire a host, run `secrets host rm newbox`. That removes its own file,
its stored key and its access to shared files. It does not remove what the
host has already read, so rotate anything it could see.

## A new workstation, to edit

Clone this repository. Then any command that needs the master key asks for
its passphrase once:

```sh
secrets unlock      # or just run the first `secrets get` or `edit`
```

- **Linux:** the key goes into the kernel user keyring and stays until
  reboot. Every shell and user service of yours can read it.
- **macOS:** the key goes into the login Keychain. It survives a reboot.
- **Either:** `secrets lock` removes it.

On a machine with a TPM (`/dev/tpmrm0`), skip the passphrase for good:

```sh
secrets tpm-enroll
```

This makes a TPM-bound age key in `~/.config/sops/age/tpm.txt` and adds it to
`keys.json` as `<hostname>-tpm`. Then it re-encrypts every file to it, which
needs the master key that one time. Commit the result. The master key stays
an admin as the backup.

## Daily use

FILE is relative to `sops/`. KEY is a dotted path, such as `aid.token`.

```sh
secrets edit hosts/hetztop.yaml            # whole file in $EDITOR
secrets get user.yaml kagi-token
printf %s "$token" | secrets set user.yaml kagi-token
secrets status                             # JSON: unlocked, TPM, admins, hosts
```

`set` reads the value from stdin and refuses an empty one. It creates the
file if the file does not exist. `secrets create FILE < plain.yaml` encrypts
a whole new file. That needs only public keys, so an agent can do it without
the passphrase.

Plain `sops` works too: `SOPS_AGE_KEY_CMD=secrets key` is in the session of
every host.

### Using a secret

- **System:** `sops.secrets.<name> = { };` in the host configuration. Read it
  at `config.sops.secrets.<name>.path`, which is `/run/secrets/<name>`, owned
  by root, mode 0400. The default file is `hosts/<host>.yaml`; set `sopsFile`
  for another.
- **Your user**, in a home-manager module:
  `croshome.userSecrets.<name> = { };` reads `user.yaml`. Add
  `.file = ../secrets/sops/hosts/<host>.yaml;` for a host file. Read it at
  `config.croshome.userSecrets.<name>.path`, which is
  `/run/secrets/lillecarl/<name>`, owned by you. The system decrypts it. cros
  has no system, so nothing decrypts it there.

A wrong name fails the build, and the error names the key and the file.

### Who reads what

`keys.json` is the only list. Edit it with `secrets host ...` and `secrets
admin add|rm NAME AGE1...`. If you edit it by hand, run `secrets sync` after.

## The master key

`./identity.age` is an age identity, encrypted with a passphrase at scrypt
work factor 21. Decryption takes about 2 GiB of memory and 3 seconds. The
memory cost is what makes guessing expensive. A longer passphrase still adds
more than a higher work factor.

If you lose the passphrase, you lose the master key. The hosts still decrypt
their own files, and a TPM admin can still edit. Without either, nobody can
edit anything.

To replace it:

```sh
age-keygen -o identity.txt
read -s pw
AGE_PASSPHRASE_FD=3 AGE_PASSPHRASE_WORK_FACTOR=21 \
  age -e -j batchpass -a -o identity.age identity.txt 3< <(printf '%s' "$pw")
```

Use fd 3, not fd 0. The plugin talks its own protocol on stdin, and fd 0
deadlocks. Put the new public key at `admins.master` in `keys.json`. Then run
`secrets sync` while the old key is still unlocked, run `secrets lock`, and
delete `identity.txt`.

## OpenPGP

Two keys, which follow the commit author split:

| Name | User IDs | Signs |
| --- | --- | --- |
| `pgp-work` | Carl Andersson <carl.andersson@dynamist.se> | everything else |
| `pgp-personal` | lillecarl <prettygood@lillecarl.com><br>lillecarl <git@lillecarl.com> | this repository |

GitHub and GitLab show a signature as verified only when the commit address is
a user ID on the key. `../home/vcs.nix` commits as `git@lillecarl.com` here,
so the personal key must carry that address. Check this before you add an
address to `./pgp-create`.

Each key is an ed25519 primary that only certifies. It has an ed25519 signing
subkey and a cv25519 encryption subkey.

- `./pgp-create` made the keys, once. It stores them in `sops/admin.yaml`.
- `./pgp-import [work|personal]` puts them into GnuPG, once per machine.
  `--status` needs no passphrase.
- `pgp-unlock` caches both key passphrases in gpg-agent, once per boot.

Two passphrases protect each key: its own, and the master key's. If you lose
either one, you lose the key. Keep both in a password manager.

### The Bitwarden copy

The vault item `OpenPGP keys (croshome)` holds `identity.age`,
`pgp-work.age`, `pgp-personal.age` and a revocation certificate for each key.
The two `.age` files are encrypted to the master key, so they open without
this repository:

```sh
age -d -i identity.age pgp-personal.age | gpg --import
```

The revocation certificates exist only there and in
`~/.gnupg/openpgp-revocs.d` on the machine that ran `./pgp-create`. Whoever
holds one can revoke the key, so they are not in this repository.

### Renewal

Both keys expire two years after creation. Renewal keeps the fingerprint:

```sh
gpg --quick-set-expire <fingerprint> 2y '*'
gpg --export-secret-keys --armor <fingerprint> | secrets set admin.yaml pgp-work
gpg --send-keys <fingerprint>     # keys.openpgp.org
```

Upload the public key to GitHub and GitLab again too, so they show the new
expiry.
