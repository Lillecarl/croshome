# The runner: the scripts that start the VM, reach into it, and shut it down.
#
# This is the lift target for nixpkgs. It knows nothing about nix-darwin -- no
# launchd, no options, no activation -- and takes the guest system and the
# settings it needs as arguments. ./default.nix is the nix-darwin half that
# wires it up; ./guest.nix is the NixOS system it boots.
#
# The hypervisor is vzvm (Apple's Virtualization.framework). The guest is
# reached over vsock, not by name: vzvm forwards a loopback TCP port into the
# guest's vsock, so the host needs no guest IP and no mDNS. ./guest.nix serves
# sshd on that vsock port.
{
  lib,
  pkgs,
  cfg,
  guest,
  ...
}:
let
  inherit (guest.config.system.build) kernel netbootRamdisk toplevel;

  # Where the public half of the builder key is staged for the guest. Only the
  # public half: /etc/nix holds the private key too, and the guest has no
  # business seeing that directory.
  keyDir = "${cfg.stateDir}/keys";

  # What the running VM was started from, so activation can tell a stale one
  # from a current one. Holds the guest's toplevel and the vzvm pid.
  runningFile = "${cfg.stateDir}/running";

  # Build outputs, scratch and swap, on real disks rather than in RAM.
  #
  # Build scratch used to be a virtiofs share of a host directory. That put it
  # on the SSD but gave it the host's clock, and the guest runs about 70ms
  # behind macOS -- so files came back with an mtime in the guest's future and
  # meson reported clock skew. It lives on the guest's own ext4 now. See
  # ./guest.nix.
  #
  # netboot puts the overlay's upper layer on a tmpfs, so every build *output*
  # was charged to guest RAM and capped at half of it -- 3.9 GiB of the 8. A
  # build large enough to exceed that died, which is what these two images fix.
  #
  # Recreated on every start, so they are ephemeral. That costs nothing:
  # `truncate` writes no data, the guest's mkfs.ext4 leaves the image sparse,
  # and it is the same /nix volume the activation check already proves is
  # case-sensitive.
  storeDisk = "${cfg.imageDir}/vz-store.img";
  swapDisk = "${cfg.imageDir}/vz-swap.img";

  # Delivered over the key share at start-up, like the builder key beside it,
  # so changing who may log in does not rebuild the guest.
  authorizedKeysFile = pkgs.writeText "vz-builder-authorized-keys" (
    lib.concatLines cfg.authorizedKeys
  );

  # `vzrun` verifies the guest against the public half of the fixed key
  # ./guest.nix installs, taken from the same nixpkgs the guest is built from.
  # So there is no first-use prompt, and no entry written into your own
  # known_hosts for a machine that is rebuilt every few minutes.
  knownHosts = pkgs.writeText "vz-builder-known-hosts" ''
    vz-builder ${builtins.readFile "${cfg.nixpkgs}/nixos/modules/profiles/keys/ssh_host_ed25519_key.pub"}
  '';

  # The vzvm configuration. Every value here is known before the VM starts;
  # the core count and whether Rosetta is installed are the two facts that are
  # not, and the runner fills them in with jq. vzvm rejects unknown keys, so
  # this has to match its schema exactly -- see nixos/modules/virtualisation/
  # vz-vm.nix in the same nixpkgs, which builds the same object.
  vzConfig = pkgs.writeText "vz-builder-vzvm.json" (builtins.toJSON {
    memorySizeMiB = cfg.memory;
    kernel = "${kernel}/Image";
    initrd = "${netbootRamdisk}/initrd";
    cmdline = "console=hvc0 init=${toplevel}/init";
    nestedVirtualization = cfg.nestedVirtualization;

    console = {
      mode = "file";
      path = "${cfg.stateDir}/console.log";
    };

    # Host TCP to guest vsock. The guest's sshd listens on vsock:22 (see
    # ./guest.nix), and `connect` below dials this loopback port, so a build
    # needs no address in the guest's NAT and no name resolution.
    vsock.forwards = [
      {
        listen = "127.0.0.1:${toString cfg.internalPort}";
        vsockPort = 22;
      }
    ];

    # Order matters to vzvm: the first disk is /dev/vda, the second /dev/vdb.
    # ./guest.nix keys the store layer off vda and swap off vdb.
    disks =
      [ { path = storeDisk; readOnly = false; } ]
      ++ lib.optional (cfg.swapSize > 0) { path = swapDisk; readOnly = false; };

    shares =
      [ { tag = "keys"; path = keyDir; } ]
      ++ lib.optional (cfg.hostStore != "off") { tag = "hostnix"; path = "/nix"; };
  });

  # Run a Linux command in the builder, for the Linux-only things a Nix build
  # cannot do: anything that wants a network, a real /proc, a mount namespace,
  # or just a shell.
  #
  # Nothing about it is special-cased on the host side. It connects to the same
  # port a distributed build does, so it starts the VM the same way, and the
  # idle watchdog counts its connection the same way -- an open session holds
  # the VM up and closing it starts the clock.
  vzrun = pkgs.writeShellApplication {
    name = "vzrun";
    runtimeInputs = [ pkgs.openssh ];
    text = ''
      user=builder
      if [ "''${1-}" = "--root" ]; then
        user=root
        shift
      fi

      # The multiplexing socket lives under ~/.ssh, which is already private to
      # the user; /tmp would let another local account on this Mac connect to a
      # master that is already authenticated. The path must stay under 104
      # bytes, macOS's unix socket limit, and %C alone is 64 of them -- which
      # rules out $TMPDIR. Create the directory, since ssh will not.
      /bin/mkdir -p "$HOME/.ssh"

      opts=(
        -p ${toString cfg.port}
        -l "$user"
        -o HostKeyAlias=vz-builder
        -o UserKnownHostsFile=${knownHosts}
        -o StrictHostKeyChecking=yes
        # Multiplexing, because this is meant to be called in a loop: a warm VM
        # answers a fresh handshake in about 150ms and a reused one in about
        # 20ms. ControlPersist stays well under idleTimeout
        # (${toString cfg.idleTimeout}s) so a forgotten master cannot pin the VM
        # up. Socket path and directory are set up above; see there.
        -o ControlMaster=auto
        -o "ControlPath=$HOME/.ssh/vzrun-%C"
        -o ControlPersist=30
      )

      if [ -t 0 ] && [ -t 1 ]; then
        opts+=(-t)
      else
        opts+=(-T)
      fi

      # Start in the same directory when the guest has one by that name. It
      # often does, and that is the point: /nix/store in the guest is this
      # Mac's store through the overlay, so a store path you are standing in
      # here is the same path there. `nix build` something for Linux, then run
      # ./result/bin/x under vzrun. Otherwise fall back to /scratch, which is
      # on the guest's disk and writable by anyone -- unlike Nix's build
      # directory, which is root-owned and was where this used to land.
      cd_to="cd $(printf '%q' "$PWD") 2>/dev/null || cd /scratch"

      if [ "$#" -eq 0 ]; then
        remote="$cd_to; exec \"\$SHELL\""
      else
        remote="$cd_to; exec $(printf '%q ' "$@")"
      fi

      # Quoted twice for two parses: sshd hands the string to the remote login
      # shell, which then hands the script to `bash -l`. The login shell is
      # what puts a usable PATH in front of the command.
      exec ssh "''${opts[@]}" 127.0.0.1 -- bash -lc "$(printf '%q' "$remote")"
    '';
  };

  runVm = pkgs.writeShellApplication {
    name = "vz-builder-vm";
    runtimeInputs = [
      cfg.vzvm
      pkgs.coreutils
      pkgs.procps
      pkgs.jq
    ];
    text = ''
      # Read at start-up rather than baked in, so this follows the machine it
      # runs on instead of pinning one Mac's core count into the repo.
      cpus=${if cfg.cores == null then "$(/usr/sbin/sysctl -n hw.ncpu)" else toString cfg.cores}

      # Sparse and fresh every start. A 128 GiB store disk occupies about 6 MiB
      # once formatted, and the guest's mkfs.ext4 takes ~95ms at any size
      # between 32 and 256 GiB -- measured, because `fileSystems.autoFormat`
      # gives no way to pass mkfs options and a filesystem that wrote its inode
      # tables eagerly would have cost seconds on a seven-second boot.
      rm -f ${lib.escapeShellArg storeDisk} ${lib.escapeShellArg swapDisk}
      truncate -s ${toString cfg.diskSize}M ${lib.escapeShellArg storeDisk}
      ${lib.optionalString (cfg.swapSize > 0) ''
        truncate -s ${toString cfg.swapSize}M ${lib.escapeShellArg swapDisk}
      ''}

      install -d -m 0755 ${lib.escapeShellArg keyDir}
      install -m 0444 ${lib.escapeShellArg "${cfg.builderKey}.pub"} ${lib.escapeShellArg keyDir}/builder_ed25519.pub
      install -m 0444 ${authorizedKeysFile} ${lib.escapeShellArg keyDir}/authorized_keys
      ${lib.optionalString cfg.shareUserSshKeys ''
        # The invoking user's key material, for outbound SSH from the guest.
        # Staged per start so rotation needs no rebuild, beside the keys above
        # rather than on a second share. Only regular files: agent and
        # multiplex sockets cannot cross into the guest anyway, and the guest
        # fixes ownership and modes on its side (see ./guest.nix).
        user=$(/usr/bin/stat -f %Su /dev/console)
        if [ -n "$user" ] && [ "$user" != root ]; then
          user_home=$(eval echo "~$user")
          if [ -d "$user_home/.ssh" ]; then
            install -d -m 0755 ${lib.escapeShellArg keyDir}/user
            for f in "$user_home"/.ssh/*; do
              [ -f "$f" ] || continue
              install -m 0600 "$f" ${lib.escapeShellArg keyDir}/user/
            done
          else
            echo "vz-builder: no .ssh for $user, guest gets no user keys" >&2
          fi
        fi
      ''}

      # Rosetta has to be present on the host; `softwareupdate --install-rosetta`
      # puts it there. vzvm refuses to start when it is asked for and missing,
      # so it is turned off here rather than left fatal: without it the VM still
      # boots and still builds aarch64-linux, it just cannot answer for
      # x86_64-linux.
      rosetta=false
      if [ -d /Library/Apple/usr/libexec/oah ]; then
        rosetta=true
      else
        echo "vz-builder: Rosetta is not installed; x86_64-linux will not work" >&2
      fi

      config=${lib.escapeShellArg "${cfg.stateDir}/vzvm.json"}
      trap 'rm -f "$config" ${lib.escapeShellArg runningFile}' EXIT

      jq --argjson cpus "$cpus" --argjson rosetta "$rosetta" \
        '.cpuCount = $cpus | .rosetta = $rosetta' \
        ${lib.escapeShellArg (toString vzConfig)} > "$config"

      ${lib.getExe cfg.vzvm} "$config" &
      vm=$!

      # Recorded for the activation check in ./default.nix, and cleared on the
      # way out so a dead VM never looks live.
      printf '%s\n%s\n' ${lib.escapeShellArg toplevel} "$vm" > ${lib.escapeShellArg runningFile}

      # Idle shutdown. A connection is live exactly while its handler runs, so
      # counting handlers is an accurate idle test and needs nothing from the
      # guest. Without this the VM would outlive the build that started it and
      # keep holding the RAM this design exists to give back.
      idle=0
      while kill -0 $vm 2>/dev/null; do
        sleep 15
        if pgrep -f vz-builder-connect >/dev/null; then
          idle=0
        else
          idle=$((idle + 15))
          if [ "$idle" -ge ${toString cfg.idleTimeout} ]; then
            echo "vz-builder: idle for ${toString cfg.idleTimeout}s, shutting down" >&2
            # Plain SIGTERM. vzvm answers it by asking the guest to stop and
            # waiting for it, then forcing it if that does not land, so the
            # guest powers off and releases the socket rather than being
            # pulled. Contrast vfkit, whose requestStop is an ACPI event this
            # direct-kernel-boot guest cannot receive, making every stop a hard
            # kill -- and the mDNS goodbye that never came is what the vsock
            # path here replaces.
            kill $vm 2>/dev/null || true
            break
          fi
        fi
      done
      wait $vm 2>/dev/null || true
    '';
  };

  # launchd hands this an accepted connection on stdin/stdout. It brings the VM
  # up if it is not already, waits for the guest to answer, then gets out of
  # the way and just moves bytes.
  connect = pkgs.writeShellApplication {
    name = "vz-builder-connect";
    runtimeInputs = [
      pkgs.bash
      pkgs.socat
      pkgs.coreutils
    ];
    text = ''
      /bin/launchctl kickstart system/org.nixos.${cfg.daemonName} 2>/dev/null || true

      # Wait for the guest, not for the VM. vzvm accepts a forwarded connection
      # at once and holds it until the guest's sshd answers, so an SSH banner
      # on the loopback port is the guest being ready. Bounded by a wall-clock
      # deadline, so a guest that never boots fails the build instead of
      # hanging it -- the failure a stale mDNS registration used to cause here.
      ready=0
      deadline=$(( SECONDS + ${toString cfg.bootTimeout} ))
      while [ "$SECONDS" -lt "$deadline" ]; do
        if [ "$(timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/${toString cfg.internalPort} && head -c 4 <&3' 2>/dev/null)" = "SSH-" ]; then
          ready=1
          break
        fi
        sleep 0.25
      done

      if [ "$ready" -ne 1 ]; then
        echo "vz-builder-connect: the guest did not answer on 127.0.0.1:${toString cfg.internalPort} within ${toString cfg.bootTimeout}s" >&2
        exit 1
      fi

      # Deliberately not `exec socat`. The idle watchdog in runVm above finds a
      # live connection with `pgrep -f vz-builder-connect`, and exec replaces
      # this process image, so the name it greps for disappears the instant the
      # handler starts moving bytes. Every open connection then looked idle and
      # the VM shut down under running builds, which surfaces as "Nix daemon
      # disconnected unexpectedly (maybe it crashed?)" -- a message that points
      # at the guest and not at the host that killed it. Keeping the wrapper
      # process alive costs one shell per open connection and makes the
      # watchdog's "counting handlers" comment true.
      socat STDIO TCP:127.0.0.1:${toString cfg.internalPort},connect-timeout=5
    '';
  };
in
{
  inherit
    keyDir
    runningFile
    storeDisk
    swapDisk
    authorizedKeysFile
    knownHosts
    vzrun
    runVm
    connect
    ;
}
