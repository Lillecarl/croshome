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
  ];

  # `age.identityPaths` is deliberately unset. Its default is already what this
  # repo wants on both machines:
  #
  #   darwin  /etc/ssh/ssh_host_ed25519_key and the rsa one beside it
  #   NixOS   the ed25519 and rsa keys of `services.openssh.hostKeys`
  #
  # The install script skips any identity that is missing, unreadable or empty
  # rather than failing, so the rsa entry costs nothing on a machine that has
  # no rsa key. It warns instead, and only if *every* identity is unusable.

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
