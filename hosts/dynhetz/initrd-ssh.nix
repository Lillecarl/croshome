# Remote LUKS unlock. ./disko.nix's root volume asks for a passphrase at
# every boot (`boot.initrd.luks.devices.cryptroot`, wired up by disko because
# the LUKS device there sets neither `keyFile` nor `passwordFile`), and
# there's no keyboard on a dedicated server -- Hetzner's own KVM console is a
# fallback, not something to depend on. This brings up the same static
# network the real OS uses and runs sshd in the initrd, so the passphrase can
# be typed in over ssh instead.
{ lib, ... }:
{
  boot.initrd.network = {
    enable = true;
    ssh = {
      enable = true;
      port = 22;
      # A dedicated keypair, not the host's regular ssh key: the initrd's
      # nix store is world-readable, so anything named here as a store path
      # leaks -- checking the private half into the repo, plainly, is fine
      # for exactly the reason that warning names. Losing it costs nothing
      # but an ssh host-key warning on the next reconnect; it authenticates
      # the server to the operator, not the other way around, and it's
      # baked into the closure via `environment.etc` below rather than
      # staged on at install time -- a bare path here reads at *activation*
      # time (systemd-boot's own bootloader-install step, which also runs
      # inside `make-disk-image.nix`'s image build), and this file has to
      # already exist on the system's own closure by then.
      hostKeys = [ "/etc/secrets/initrd/ssh_host_ed25519_key" ];
      authorizedKeys = [ (lib.readFile ../../lillecarl.pub) ];
    };
  };

  environment.etc."secrets/initrd/ssh_host_ed25519_key" = {
    source = ./initrd_ssh_host_ed25519_key;
    mode = "0600";
  };

  # Same addresses, same quirk as ../default.nix's real networking -- both
  # families, not just IPv4, so a reconnect over either one still reaches the
  # initrd. Hetzner routes the whole /26 to this MAC, and the IPv4 gateway
  # sits outside it, so the kernel needs telling to treat it as on-link
  # rather than trying to ARP a neighbour it can't otherwise resolve inside
  # the /26; the IPv6 gateway is link-local, which is on-link by definition,
  # so it needs no such hint.
  boot.initrd.systemd.network.networks."10-eth0" = {
    matchConfig.Name = "eth0";
    address = [
      "37.27.129.237/26"
      "2a01:4f9:3071:11d7::2/64"
    ];
    routes = [
      {
        Gateway = "37.27.129.193";
        GatewayOnLink = true;
      }
      {
        Gateway = "fe80::1";
      }
    ];
    networkConfig.DHCP = "no";
  };
}
