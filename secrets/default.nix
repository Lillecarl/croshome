{ inputs, pkgs, ... }:
{
  # agenix is `flake = false`, so this is the source tree and no second flake
  # is evaluated -- the same treatment nanopynix gets in ../hosts/*/default.nix,
  # and see ../flake.nix for why it matters more here.
  #
  # One file serves both machines. It decides which it is on at evaluation time
  # by asking whether `environment.darwinConfig` is a declared option, and
  # branches on that for the parts that cannot be shared: launchd against
  # systemd, an hdiutil ramdisk against a ramfs mount, group `admin` against
  # group `keys`.
  imports = [ "${inputs.agenix}/modules/age.nix" ];

  # The CLI, for `agenix -e` and `agenix -r`. `callPackage` against this repo's
  # own package set, so it links the same `age` the module runs.
  #
  # It reads ./secrets.nix through the `RULES` variable, which defaults to
  # ./secrets.nix relative to the working directory. So run it from this
  # directory, or set RULES.
  environment.systemPackages = [
    (pkgs.callPackage "${inputs.agenix}/pkgs/agenix.nix" { })

    # `age` itself, which agenix does not put on the PATH. It references the
    # binary by store path through `ageBin`, so age lands in the closure and
    # nowhere a shell can reach it.
    #
    # ./README.md asks for `age-keygen` and `age -p` to create the identity, so
    # those have to exist. ./unlock needs `age` too, and falls back to
    # `nix run nixpkgs#age` only on a machine this configuration has never
    # activated.
    pkgs.age
  ];

  # The age identity ./unlock writes, ahead of the host keys rather than
  # instead of them. agenix tries every readable entry in turn, so a secret
  # encrypted to either one still opens.
  #
  # The defaults are kept because they are already right, and because they are
  # what works on a machine where ./unlock has never run:
  #
  #   darwin  /etc/ssh/ssh_host_ed25519_key and the rsa one beside it
  #   NixOS   the ed25519 and rsa keys of `services.openssh.hostKeys`
  #
  # A missing, unreadable or empty entry is skipped rather than fatal -- the
  # install script tests each with `-r` and `-s` first. So this path costs
  # nothing before ./unlock has run, and the rsa entries cost nothing on a
  # machine with no rsa key. agenix warns only when *every* identity is
  # unusable.
  # Stated flat, not derived. Both hosts resolved to the same two host key
  # paths anyway -- checked by evaluating each -- so a platform branch here
  # would have had two identical arms.
  age.identityPaths = [
    "/var/lib/agenix/identity"
    "/etc/ssh/ssh_host_ed25519_key"
    "/etc/ssh/ssh_host_rsa_key"
  ];

  # No secrets yet, and while this is empty the module adds nothing at all:
  # its whole `config` sits behind `mkIf (cfg.secrets != { })`. No launchd
  # daemon, no ramdisk, no activation step. Only the CLI above is installed.
  #
  # The shape of an entry:
  #
  #   age.secrets.wg0-key = {
  #     file = ./wg0.key.age;      # the encrypted file, checked in
  #     path = "/etc/wireguard/wg0.key";  # optional; /run/agenix/<name> otherwise
  #     owner = "root";
  #     group = "wheel";
  #     mode = "0400";
  #   };
  #
  # Decrypted secrets land on a ramdisk under /run/agenix.d and are symlinked
  # into /run/agenix, one generation per activation. Nothing plaintext is
  # written to disk, and nothing survives a reboot -- each boot decrypts again
  # from the host key.
  age.secrets = { };
}
