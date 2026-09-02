# Remote LUKS unlock. ./disko.nix's root volume asks for a passphrase at
# every boot (`boot.initrd.luks.devices.cryptroot`, wired up by disko because
# the LUKS device there sets neither `keyFile` nor `passwordFile`), and
# there's no keyboard on a dedicated server -- Hetzner's own KVM console is a
# fallback, not something to depend on. This brings up the same static
# network the real OS uses and runs sshd in the initrd, so the passphrase can
# be typed in over ssh instead.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # `ssh root@host` alone leaves you at a bare shell with nothing pending
  # visibly -- unlocking still means knowing to run
  # systemd-tty-ask-password-agent yourself. Run it automatically instead,
  # but not via `exec`: an operator who ctrl-c's out of a wait (because the
  # prompt isn't a LUKS passphrase after all, or they want a shell for other
  # initrd troubleshooting) lands in a real shell rather than losing the ssh
  # session.
  initrdUnlockShell = pkgs.writeShellScript "initrd-unlock-shell" ''
    ${config.boot.initrd.systemd.package}/bin/systemd-tty-ask-password-agent --query --watch
    exec ${pkgs.bashInteractive}/bin/bash
  '';
in
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

  # boot.initrd.network.ssh's own `shell` option is for the legacy
  # dropbear-based initrd; systemd-based initrd (boot.initrd.systemd.enable,
  # true here) reads the login shell from here instead.
  boot.initrd.systemd.users.root.shell = "${initrdUnlockShell}";
  boot.initrd.systemd.storePaths = [ initrdUnlockShell ];

  # A second login name, purely for convenience: `ssh lillecarl@host` instead
  # of `ssh root@host` to unlock, matching the name used everywhere else. Not
  # uid 0 -- NixOS's own initrd-systemd-users module asserts uids are unique,
  # so aliasing to root isn't an option here. It doesn't need to be root
  # anyway: systemd's ask-password socket is meant to be answerable by an
  # unprivileged agent (that's how desktop session agents supply LUKS
  # passphrases too), so any uid can run the unlock agent. initrd-ssh.nix's
  # own module only auto-populates /etc/ssh/authorized_keys.d/root; its
  # sshd_config still matches any other %u against
  # /etc/ssh/authorized_keys.d/%u, so that file is the only other piece a
  # second login name needs.
  boot.initrd.systemd.users.lillecarl = {
    uid = 1000;
    group = "root";
    shell = "${initrdUnlockShell}";
  };
  boot.initrd.systemd.contents."/etc/ssh/authorized_keys.d/lillecarl".text = lib.readFile ../../lillecarl.pub;

  # A physical keyboard never times out waiting for a LUKS passphrase; this
  # ssh path has to behave the same way, and by default it doesn't.
  # systemd's ~90s DefaultDeviceTimeoutSec applies to the .device units
  # downstream of cryptroot (Initrd Root Device, /sysroot, ...), and that
  # clock starts at boot -- not when an operator finally notices the reboot
  # and gets a passphrase typed in over ssh. Confirmed on the real machine:
  # those units failed at t+~80s, cascading into emergency mode, while the
  # LUKS unlock itself (however long the human took) hadn't happened yet --
  # requiring a keypress at the console to continue even though nothing was
  # actually broken. The VM test never caught this because its scripted
  # unlock answers in under 2 seconds, nothing like a real operator's pace.
  boot.initrd.systemd.settings.Manager.DefaultDeviceTimeoutSec = "infinity";

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
