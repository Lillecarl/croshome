# Secrets

sops-nix. The secrets are YAML files in `./sops`, and each value is encrypted.
Each file is encrypted to the master key and to the hosts that read it.

| Who | Key it uses | Passphrase |
| --- | --- | --- |
| You, editing | `./identity.age`, the master key | Once per boot |
| A host, at activation | its ssh host key, `/etc/ssh/ssh_host_ed25519_key` | No |

No host holds the master key. Taking one host gives the secrets of that host
only.

## Files

| File | Read by |
| --- | --- |
| `sops/hosts/<host>.yaml` | that host |
| `sops/user.yaml` | every host, decrypted for your user |
| `sops/dc1.yaml` | dynhetz and macbook (the dc1 WireGuard key) |
| `sops/admin.yaml` | nobody unattended (the OpenPGP keys) |

`sops/keys.nix` lists the master key, each host key and which hosts read
which file. It is the only list of recipients. `sops/.sops.yaml` is made from
it. Do not edit `.sops.yaml` by hand.

## Daily use

`secrets` is on the PATH of every host. FILE is relative to `sops/`; KEY is a
dotted path.

```sh
secrets edit hosts/hetztop.yaml       # opens the decrypted file in $EDITOR
secrets get user.yaml kagi-token
printf %s "$token" | secrets set user.yaml kagi-token
secrets status                        # JSON: unlocked?, TPM identity?
secrets lock                          # forget the master key now
```

The first command that needs the master key asks for its passphrase. Then
`secrets` keeps the key in the kernel keyring, with no time limit. Every
shell and user service of yours can then read it, and a reboot removes it.
Plain `sops` works too: `SOPS_AGE_KEY_CMD=secrets key` is in the session.

`secrets create FILE` makes a new file from plaintext YAML on stdin. It needs
only public keys, so it needs no passphrase.

## Adding a secret

1. `printf %s "$value" | secrets set hosts/<host>.yaml <name>`
2. Use it in that host's configuration:
   - system: `sops.secrets.<name> = { };`, then `config.sops.secrets.<name>.path`
     (`/run/secrets/<name>`, root, 0400)
   - your user, in a home-manager module: `croshome.userSecrets.<name>.file =
     ../secrets/sops/hosts/<host>.yaml;`, then
     `config.croshome.userSecrets.<name>.path`
     (`/run/secrets/lillecarl/<name>`). Without `file`, it reads `user.yaml`.

A wrong name fails the build, and the error names the key and the file.

## Adding a host

1. On the host: `ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub`
2. Add the result under `hosts` in `sops/keys.nix`, and add the host to the
   shared files it reads under `files`.
3. `secrets sync`. It writes `.sops.yaml` and re-encrypts each file to it.

A host that is missing from `keys.nix` fails the build with these steps.

## A TPM instead of the passphrase

On a machine with a TPM (`/dev/tpmrm0`):

```sh
secrets tpm-enroll    # prints a recipient
```

Add the recipient under `admins` in `sops/keys.nix`, then run `secrets sync`.
That machine then decrypts through the TPM and never asks for the passphrase.
The passphrase key stays an admin, as the backup.

## The master key

`./identity.age` is an age identity, encrypted with a passphrase at scrypt
work factor 21. Decryption takes about 2 GiB of memory and 3 seconds. The
memory cost is what makes guessing expensive. A stronger passphrase still
adds more than a higher work factor.

To make a new one (this changes every file's recipient):

```sh
age-keygen -o identity.txt
read -s pw
AGE_PASSPHRASE_FD=3 AGE_PASSPHRASE_WORK_FACTOR=21 \
  age -e -j batchpass -a -o identity.age identity.txt 3< <(printf '%s' "$pw")
```

Use fd 3, not fd 0: the plugin talks its own protocol on stdin, and fd 0
deadlocks. Put the new public key under `admins`, run `secrets sync`, then
delete `identity.txt`.

If the passphrase is lost, the master key is lost. The hosts can still decrypt
their own files, but nobody can edit any file.

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

Each key is an ed25519 primary that only certifies, with an ed25519 signing
subkey and a cv25519 encryption subkey.

- `./pgp-create` made the keys, once. It stores them in `sops/admin.yaml`.
- `./pgp-import [work|personal]` puts them into GnuPG on a machine, once per
  machine. `--status` needs no passphrase.
- `pgp-unlock` caches both key passphrases in gpg-agent, once per boot.

Two passphrases protect each key: its own, and the master key's. If you lose
either one, you lose the key. Keep both in a password manager.

### The Bitwarden copy

The vault item `OpenPGP keys (croshome)` holds `identity.age`,
`pgp-work.age`, `pgp-personal.age` and a revocation certificate per key. The
two `.age` files are encrypted to the master key, so they open without this
repository:

```sh
age -d -i identity.age pgp-personal.age | gpg --import
```

The revocation certificates are only there and in
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
