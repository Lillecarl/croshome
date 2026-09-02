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
  #
  # `trap : INT` is load-bearing, not decoration. Without it this never
  # actually worked: a non-interactive script has no job control, so a
  # ctrl-c-generated SIGINT hits the whole foreground process group --
  # script and agent both -- and bash's default reaction to SIGINT in a
  # non-interactive script is to exit immediately, before it ever reaches
  # `exec bash`. Confirmed on the real machine: ctrl-c during the wait just
  # dropped the ssh session instead of handing back a shell. Trapping SIGINT
  # with a real (no-op) handler keeps the script itself alive; the trap
  # is *not* inherited across exec, so the agent child still gets SIGINT's
  # normal default (terminate) and the wait still ends there.
  initrdUnlockShell = pkgs.writeShellScript "initrd-unlock-shell" ''
    trap : INT
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
  # of `ssh root@host` to unlock, matching the name used everywhere else.
  # Has to be uid 0, not just group root: /run/systemd/ask-password is
  # root-only, and answering a boot-critical password request (the LUKS
  # passphrase) is deliberately a privileged operation in systemd -- a
  # uid-1000 lillecarl authenticated fine and got a shell, but the agent
  # inside it could never actually answer the pending request. Confirmed on
  # the real machine: root still unlocked, lillecarl connected but couldn't.
  # NixOS's own module normally forbids a second account at uid 0 (it
  # enforces unique uids for exactly this kind of accident), so that check
  # is turned off below -- this is a deliberate alias, not a mistake, the
  # same trick as the classic `toor` account.
  boot.initrd.systemd.users.lillecarl = {
    uid = 0;
    group = "root";
    shell = "${initrdUnlockShell}";
  };
  boot.initrd.systemd.contents."/etc/ssh/authorized_keys.d/lillecarl".text = lib.readFile ../../lillecarl.pub;
  users.enforceIdUniqueness = false;

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
  #
  # Not `"infinity"` -- that was tried first and made things worse. It
  # applies to every initrd .device unit, not just the ones gated on a
  # human typing a passphrase, so a genuine downstream failure (LVM
  # autoactivation not firing, a mount that never appears, anything
  # unrelated to the passphrase) now waits forever too, with nothing left
  # to time out and drop to a rescue shell. Confirmed on the real machine:
  # /dev/mainpool/root sat as "a start job is running ... no limit"
  # indefinitely, ssh to the initrd stopped answering, and only a hard
  # reset via the KVM recovered it -- worse than the original ~90s trip,
  # which was at least recoverable. Three separate real boots showed LVM
  # activation itself completing in well under a second once cryptsetup
  # finished, so the slow, human-paced part is entirely the passphrase
  # prompt; a generous but finite window covers that while still leaving a
  # real timeout for anything that isn't waiting on a human.
  boot.initrd.systemd.settings.Manager.DefaultDeviceTimeoutSec = "45min";

  # What the 45 minute timeout above actually leads to, once it trips:
  # nothing, on its own. NixOS's initrd drops to emergency.target on a
  # failure like this, which runs `sulogin` -- and `emergencyAccess` isn't
  # set below, so root's password is locked (`*`) and sulogin can never
  # authenticate. The "press enter at the KVM to continue" from before
  # wasn't a real rescue shell; it was `sulogin`'s "Control-D to continue"
  # path re-triggering the same stuck target, which only ever helped
  # because the passphrase had *already* been typed by then. A genuine
  # failure would just sit at that unusable prompt forever, needing a hard
  # reset -- exactly what "the boot must never fail" rules out.
  #
  # NixOS already ships the fix for this, gated behind a kernel command
  # line flag: `services.panic-on-fail` in the initrd systemd module is
  # `wantedBy = [ "emergency.target" ]` and, when
  # `boot.panic_on_fail`/`stage1panic` is on the command line, does
  # `echo c > /proc/sysrq-trigger` -- a deliberate kernel panic -- as soon
  # as emergency.target is reached, covering every path into it, not just
  # this specific device timeout. `panic=10` is the other half: without
  # it, the kernel's default behaviour after a panic is to halt, not
  # reboot, which would just trade one unrecoverable hang for another.
  # With it, the kernel reboots itself 10s after any panic -- not only
  # this deliberate one, but a genuine kernel panic on the fully booted
  # system too, which is exactly the outcome wanted there as well.
  boot.kernelParams = [
    "panic=10"
    "boot.panic_on_fail"
  ];

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
