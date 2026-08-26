# Proves the actual feature ./initrd-ssh.nix exists for: that connecting to
# the initrd over ssh and answering the pending LUKS passphrase prompt really
# unlocks the disk and lets boot proceed. ./vm-test.nix (disko's own
# install/reboot harness) cannot test this -- its "direct" testMode reboots
# the machine through a hand-built qemu invocation
# (disko's lib/tests.nix `create_test_machine`) that never attaches a network
# device at all, so nothing running in that reboot could ever be reached over
# ssh. This is a separate, ordinary two-node NixOS test instead, modelled on
# nixpkgs' own nixos/tests/systemd-initrd-luks-password.nix (the
# specialisation + `machine.crash()` + `machine.start()` reboot pattern,
# which -- unlike disko's reboot -- keeps the same qemu invocation and so
# keeps networking) and nixos/tests/systemd-initrd-network-ssh.nix (the
# client/server ssh-into-the-initrd pattern).
#
# Deliberately NOT layered on disko/mdadm/LVM/btrfs: that stack is what
# ./vm-test.nix already exercises, and pulling it in here would just make
# this test slower and conflate two different failure modes. A single LUKS
# volume on ext4 is everything the ssh-unlock mechanism itself needs to prove
# out; what's inside the volume doesn't change whether it can be reached and
# answered over the network.
#
#   nix-build --expr '
#     let
#       pkgs = (import ./.).pkgsFor "aarch64-linux";
#     in pkgs.testers.nixosTest (import ./hosts/dynhetz/vm-test-ssh-unlock.nix)
#   '
#
# aarch64-linux for the same reason as ./vm-test.nix: none of this is
# architecture-specific, and aarch64 runs natively on the VZ builder instead
# of under Rosetta emulation.
{ lib, pkgs, ... }:
let
  luksPassphrase = "vm-test-luks-passphrase";
in
{
  name = "dynhetz-initrd-ssh-unlock";

  nodes = {
    server =
      { config, ... }:
      {
        imports = [ ./initrd-ssh.nix ];

        virtualisation = {
          emptyDiskImages = [ 512 ];
          useBootLoader = true;
          # Booting off the encrypted disk needs the store reachable from the
          # switched-to specialisation, same as nixpkgs' own luks-password
          # test.
          mountHostNixStore = true;
          useEFIBoot = true;
          # keepVariables defaults to true whenever useBootLoader is, and
          # pulls in qemu-vm.nix's own `systemImage` (a full make-disk-image
          # build) purely to seed the EFI vars file from it -- that build
          # hardcodes `requiredSystemFeatures = [ "kvm" ]`
          # (pkgs/build-support/vm/default.nix's `runInLinuxVM`), which
          # nothing in this environment offers. Off, this seeds EFI vars
          # from the stock OVMF template instead -- a cached package, no
          # nested qemu build -- and this test has no reason to care about
          # keeping EFI variable values across the reboot it does.
          efi.keepVariables = false;
        };
        boot.loader.systemd-boot.enable = true;
        boot.initrd.systemd.enable = true;

        # ./initrd-ssh.nix hardcodes dynhetz's real Hetzner address and a
        # gateway outside its /26 -- meaningless on the nixos-test vlan.
        # Reuse the framework's own auto-assigned test address instead, so
        # both this initrd config and `client`'s ordinary `ssh server` (via
        # the test framework's /etc/hosts) resolve to the same place.
        boot.initrd.systemd.network.networks."10-eth0" = lib.mkForce {
          matchConfig.Name = "eth0";
          address = [ "${config.networking.primaryIPAddress}/24" ];
          networkConfig.DHCP = "no";
        };

        # Throwaway keys, checked in alongside this file: the real ones are
        # ../installscript.nix's staged host key and the operator's own
        # ../../lillecarl.pub, neither of which belongs in a disposable test.
        #
        # hostKeys is a plain string, matching the real config's convention
        # -- for systemd-boot, this path is read from *this VM's own disk*
        # at the moment `switch-to-configuration boot` embeds it into the
        # initrd (systemd-boot-builder.py's own handling, not the generic
        # initrd-secrets.nix copy-service, which is skipped entirely for
        # loaders with supportsInitrdSecrets = true). `useBootLoader = true`
        # means that embed step runs *while the disk image itself is being
        # built* (make-disk-image.nix installs the bootloader as part of
        # constructing the image), not only later at test-script runtime --
        # so the file has to already exist on this system's own closure from
        # the start, via `environment.etc`, not staged in by a
        # `server.succeed("cp ...")` after the fact. The first version of
        # this file tried the latter, and every disk-image build silently
        # died with zero console output -- almost certainly this same
        # bootloader-install step hitting the same "cp: cannot stat" this
        # file's config was missing, just inside a nested build VM whose
        # console isn't captured at all.
        boot.initrd.network.ssh.hostKeys = lib.mkForce [ "/etc/secrets/initrd/ssh_host_ed25519_key" ];
        boot.initrd.network.ssh.authorizedKeys = lib.mkForce [
          (lib.fileContents ./vm-test-ssh-unlock-client-key.pub)
        ];
        environment.etc."secrets/initrd/ssh_host_ed25519_key" = {
          source = ./vm-test-ssh-unlock-host-key;
          mode = "0600";
        };

        environment.systemPackages = [ pkgs.cryptsetup ];
        # For answering the ask-password request directly over its own
        # socket -- see the testScript's own note on why, below. `storePaths`
        # only copies a path's closure into the initrd's own /nix/store; it
        # doesn't put anything on PATH. `extraBin` is the option that
        # actually symlinks a binary into the initrd's /bin (and /sbin), so
        # a bare `sed`/`socat` in the ssh'd-in remote command can find it --
        # storePaths alone left both commands "not found" even though their
        # closures were present.
        boot.initrd.systemd.extraBin = {
          socat = "${pkgs.socat}/bin/socat";
          sed = "${pkgs.gnused}/bin/sed";
        };

        # Mirrors ./disko.nix's real shape closely enough to be meaningful:
        # one named LUKS volume, no keyFile/passwordFile, so it prompts
        # exactly the way the real machine will.
        specialisation.boot-luks.configuration = {
          # qemu-vm.nix forces `boot.initrd.luks.devices = mkVMOverride { }` by
          # default (useDefaultFilesystems), specifically so an ordinary VM
          # test never blocks on a password prompt it can't answer. A plain
          # assignment here loses to that override at the same normal
          # priority and silently vanishes -- the crypttab ends up empty, no
          # cryptsetup service is ever created, and `/dev/mapper/cryptroot`
          # sits "Expecting device" forever with no ask-password request to
          # answer. Matching nixpkgs' own
          # nixos/tests/systemd-initrd-luks-password.nix, `mkVMOverride` here
          # merges with that default instead of losing to it.
          boot.initrd.luks.devices = lib.mkVMOverride { cryptroot.device = "/dev/vdb"; };
          virtualisation.rootDevice = "/dev/mapper/cryptroot";
        };
      };

    client =
      { ... }:
      {
        environment.etc.sshKey = {
          source = ./vm-test-ssh-unlock-client-key;
          mode = "0600";
        };
      };
  };

  testScript =
    { nodes, ... }:
    let
      boot-luks = nodes.server.specialisation.boot-luks.configuration.system.build.toplevel;
    in
    # python
    ''
      server.start()
      client.start()

      server.wait_for_unit("multi-user.target")
      server.succeed(
          "echo -n ${luksPassphrase} | cryptsetup luksFormat -q --iter-time=1 /dev/vdb -"
      )
      server.succeed(
          "echo -n ${luksPassphrase} | cryptsetup luksOpen -q /dev/vdb cryptroot"
      )
      server.succeed("mkfs.ext4 /dev/mapper/cryptroot")

      client.wait_for_unit("network.target")

      # Reboot into the LUKS-locked specialisation. `machine.crash()` +
      # `machine.start()`, not disko's reboot: this keeps the same qemu
      # invocation (same netdev, same vlan membership), which is the whole
      # reason this test can reach the initrd over ssh at all.
      server.succeed("${boot-luks}/bin/switch-to-configuration boot")
      server.succeed("sync")
      server.crash()
      server.start()

      def ssh_is_up(_) -> bool:
          status, _ = client.execute("nc -z server 22")
          return status == 0

      with client.nested("waiting for the initrd's sshd to come up"):
          retry(ssh_is_up, timeout_seconds=60)

      # No known_hosts pinning: a first attempt pinned just "server," (the
      # hostname), and the connection was rejected before authentication --
      # ssh also checks the resolved IP against known_hosts by default, and
      # nixos' own vlan addresses each node over IPv6, which that entry
      # never covered. nixpkgs' own initrd-ssh reference test handles this
      # by extracting the exact IP and adding it as a second alias on the
      # same line; simpler here, since this test has nothing to prove about
      # host-key pinning itself, to just not pin one.
      ssh = (
          "ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null "
          "-i /etc/sshKey root@server"
      )

      # Answering once and moving on raced the crypttab service the first
      # time around: sshd comes up in parallel with (not after) the
      # device-wait that posts the password query, so answering too early
      # finds nothing pending. Retrying `systemd-tty-ask-password-agent
      # -tt ... --query` fixed the timing but never actually unlocked
      # anything even once it reliably ran *after* the request existed --
      # `-tt` over a piped, non-interactive local stdin (this whole script
      # runs through the test driver's own scripted shell, never a real
      # terminal) is a well-known source of PTY buffering races, and
      # systemd's own agent reads the answer from the allocated PTY, not
      # from a plain stdin redirect. Writing straight to the ask-password
      # socket sidesteps the TTY entirely: the request file
      # (/run/systemd/ask-password/ask.*) names a `Socket=` to send a
      # single "+<password>" datagram to, which is the same protocol the
      # agent itself speaks, just without the interactive-terminal step in
      # the middle. Still retried, and still through `client`'s ssh
      # connection rather than `server.execute()` -- the backdoor shell
      # that uses relies on the *main* system's own instrumentation
      # service, which isn't running yet while `server` is still in the
      # initrd (this is what "Shell disconnected" meant further up).
      def luks_unlocked(_) -> bool:
          client.execute(
              f"{ssh} 'for f in /run/systemd/ask-password/ask.*; do "
              "sock=$(sed -n \"s/^Socket=//p\" \"$f\"); "
              f"[ -n \"$sock\" ] && printf \"+%s\" \"${luksPassphrase}\" | socat -u STDIN \"UNIX-SENDTO:$sock\"; "
              "done'"
          )
          status, _ = client.execute(f"{ssh} test -e /dev/mapper/cryptroot")
          return status == 0

      with client.nested("unlocking cryptroot over ssh"):
          retry(luks_unlocked, timeout_seconds=60)

      server.wait_for_unit("multi-user.target")
      assert "/dev/mapper/cryptroot on / type ext4" in server.succeed(
          "mount"
      ), "cryptroot is not mounted as / after the ssh-driven unlock"
    '';
}
