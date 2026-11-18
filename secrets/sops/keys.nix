# Who can decrypt which sops file. The single source for recipients:
# ./sops-yaml.nix turns this into ./.sops.yaml, and `secrets sync` writes it and
# re-encrypts every file to match.
{
  # Recipients of every file. They edit; no host decrypts with them.
  admins = {
    # ../identity.age, passphrase-protected. `secrets` caches it in the kernel
    # keyring on first use.
    lillecarl = "age1gpep8sqp2ze8kyl82tlt2mkh58e0x933a650al2x9uavj8gnmpdq8zqdmz";
  };

  # `ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub` on each host.
  hosts = {
    dynhetz = "age1gml66rxtrvlfydyzka35fky5glvcp6q8skmyn5fk20cfqpm2x54qn7h228";
    hetztop = "age1qk3ygjqdnegp4qwd4aca63j3pyzsnnazgzkqpgputp4v9crcwf8qyeajfg";
    macbook = "age1zqpaevk0cl9txk2g4hw8h5a57xc3ad4u77yddppemm64k595jd0qycwe6z";
    shitbox = "age1jfwtm8hm6fackup2pxt2s6p4gutuyqhf9ctxezex95fpjtsd2e2s3306xr";
  };

  # File, relative to this directory, to the hosts that decrypt it. Admins are
  # added to all. `hosts/<name>.yaml` for every host is implicit.
  files = {
    "user.yaml" = [
      "dynhetz"
      "hetztop"
      "macbook"
      "shitbox"
    ];
    "dc1.yaml" = [
      "dynhetz"
      "macbook"
    ];
    # Admins only: nothing decrypts it unattended.
    "admin.yaml" = [ ];
  };
}
