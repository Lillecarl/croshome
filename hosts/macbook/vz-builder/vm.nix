# The runner: the scripts that start the VM, reach into it, and shut it down.
#
# This is the lift target for nixpkgs. It knows nothing about nix-darwin -- no
# launchd, no options, no activation -- and takes the guest system and the
# settings it needs as arguments. ./default.nix is the nix-darwin half that
# wires it up; ./guest.nix is the NixOS system it boots.
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
  # from a current one. Holds the guest's toplevel and the vfkit pid.
  runningFile = "${cfg.stateDir}/running";

  # Build outputs, scratch and swap, on real disks rather than in RAM.
  #
  # Build scratch used to be a virtiofs share of a host directory. That put it
  # on the SSD but gave it the host's clock, and the guest runs about 70ms
  # behind macOS -- so files came back with an mtime in the guest's future and
  # meson reported clock skew. It lives on the guest's own ext4 now. See
  # ./guest.nix.
  #
  # It also retires a constraint: the share had to sit under /nix because every
  # macOS-managed temp directory is on the case-insensitive boot volume, and a
  # build directory where `foo` and `FOO` collide breaks the derivations a
  # case-sensitive store exists to support. A guest filesystem has no such
  # problem. The images below stay under /nix anyway, since that is the volume
  # the activation check already proves is case-sensitive.
  #
  # netboot puts the overlay's upper layer on a tmpfs, so every build *output*
  # was charged to guest RAM and capped at half of it -- 3.9 GiB of the 8. A
  # build large enough to exceed that died, which is what these two images fix.
  #
  # Recreated on every start, like buildScratch, so they are ephemeral in the
  # same sense. That costs nothing: `truncate` writes no data, the guest's
  # mkfs.ext4 leaves the image sparse, and it is the same /nix volume the
  # activation check already proves is case-sensitive.
  storeDisk = "${cfg.imageDir}/vz-store.img";
  swapDisk = "${cfg.imageDir}/vz-swap.img";

  # vfkit's REST endpoint, which ../../../pkgs/vfkit-balloon.nix extends with
  # /vm/memory-balloon. A unix socket rather than a loopback port: the balloon
  # can shrink a running guest and /vm/state can stop it, and a socket is
  # reachable only by something that can open this path. 30 bytes, comfortably
  # inside the 104-byte limit macOS puts on a unix socket path.
  restSocket = "${cfg.stateDir}/rest.sock";

  # The guest publishes this over mDNS and mDNSResponder answers it natively,
  # so nothing here has to discover an IP.
  guestHost = "${guest.config.networking.hostName}.local";

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
      cfg.vfkit
      pkgs.coreutils
      pkgs.procps
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
      #
      # Order matters below: the store disk is added first, so it is /dev/vda
      # in the guest and swap is /dev/vdb.
      rm -f ${lib.escapeShellArg restSocket}
      rm -f ${lib.escapeShellArg storeDisk} ${lib.escapeShellArg swapDisk}
      truncate -s ${toString cfg.diskSize}M ${lib.escapeShellArg storeDisk}
      disks=(--device "virtio-blk,path=${storeDisk}")
      ${lib.optionalString (cfg.swapSize > 0) ''
        truncate -s ${toString cfg.swapSize}M ${lib.escapeShellArg swapDisk}
        disks+=(--device "virtio-blk,path=${swapDisk}")
      ''}

      install -d -m 0755 ${lib.escapeShellArg keyDir}
      install -m 0444 ${lib.escapeShellArg "${cfg.builderKey}.pub"} ${lib.escapeShellArg keyDir}/builder_ed25519.pub
      install -m 0444 ${authorizedKeysFile} ${lib.escapeShellArg keyDir}/authorized_keys

      # Rosetta has to be present on the host; `softwareupdate --install-rosetta`
      # puts it there. Without it the VM still boots and still builds
      # aarch64-linux, it just cannot answer for x86_64-linux.
      rosetta=()
      if [ -d /Library/Apple/usr/libexec/oah ]; then
        rosetta=(--device "rosetta,mountTag=rosetta")
      else
        echo "vz-builder: Rosetta is not installed; x86_64-linux will not work" >&2
      fi

      ${lib.optionalString (cfg.hostStore != "off") ''
        # Read-only, and both halves: a store path that no database knows about
        # is invisible to Nix, so the store alone would buy nothing.
        hostStore=(--device "virtio-fs,sharedDir=/nix,mountTag=hostnix")
      ''}

      vfkit \
        --cpus "$cpus" \
        --memory ${toString cfg.memory} \
        --bootloader "linux,kernel=${kernel}/Image,initrd=${netbootRamdisk}/initrd,cmdline=\"console=hvc0 init=${toplevel}/init\"" \
        --nested \
        --device virtio-rng \
        --device virtio-balloon \
        --device "virtio-net,nat" \
        --device "virtio-fs,sharedDir=${keyDir},mountTag=keys" \
        "''${disks[@]}" \
        "''${rosetta[@]}" \
        ${lib.optionalString (cfg.hostStore != "off") ''"''${hostStore[@]}" \''}
        --restful-uri "unix://${restSocket}" \
        --device "virtio-serial,logFilePath=/var/log/vz-builder.log" &
      vm=$!

      # vfkit creates the socket under root's umask, so 0755 -- and connecting
      # to a unix socket needs *write* permission, which leaves it root-only.
      # Opened up so an ordinary session can read the balloon without sudo. It
      # grants no privilege that reaching the builder on ${toString cfg.port}
      # does not already grant, that being a shell as a trusted Nix user.
      (
        for _ in $(seq 1 100); do
          if [ -S ${lib.escapeShellArg restSocket} ]; then
            chmod 0666 ${lib.escapeShellArg restSocket}
            break
          fi
          sleep 0.1
        done
      ) &

      # Recorded for the activation check in ./default.nix, and cleared on the
      # way out so a dead VM never looks live.
      printf '%s\n%s\n' ${lib.escapeShellArg toplevel} "$vm" > ${lib.escapeShellArg runningFile}
      trap 'rm -f ${lib.escapeShellArg runningFile}' EXIT

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
            # Plain SIGTERM, deliberately, and it is already the ACPI-request-
            # then-hard-kill sequence this looks like it is missing: vfkit's
            # own signal handler (cmd/vfkit/main.go's shutdownFunc) answers
            # SIGTERM by calling the guest's requestStop, waiting up to 5s for
            # VirtualMachineStateStopped, and force-`Stop()`ing only if that
            # does not land. Nothing here needs to reimplement that.
            #
            # It cannot land on this guest, though, and that is a fact about
            # this VM, not a bug in vfkit. Virtualization.framework's
            # requestStop is an ACPI power-button event, and ACPI tables are
            # an EFI-boot thing; this guest boots straight from a kernel and
            # initrd (the --bootloader "linux,..." line above, with
            # no ACPI in guest.nix's kernel modules to match), so there is
            # nothing on the guest side to receive the request. `stopped`
            # comes back false, the 5s wait always elapses, and every idle
            # shutdown is a hard stop in practice -- indistinguishable from
            # pulling power.
            #
            # That is why systemd inside the guest never runs its shutdown
            # targets and avahi never sends an mDNS goodbye for
            # ${guestHost}.local, which is what let a stale registration
            # squat that name across a restart and hang every `vzrun` dialing
            # it; `connect` above exists to bound
            # exactly that failure rather than assume it cannot recur. Fixing
            # it at the source would mean booting this guest through EFI, a
            # bigger change than this comment.
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
      pkgs.socat
      pkgs.coreutils
    ];
    text = ''
      /bin/launchctl kickstart system/org.nixos.vz-builder-vm 2>/dev/null || true

      # First connection pays the boot; later ones find it already up. Polled
      # four times a second rather than once: a whole-second granularity adds
      # half a second on average to every cold build, which is real next to a
      # boot measured in single digits.
      #
      # Each probe is wrapped in `timeout`, not just socat's own
      # connect-timeout=1. That option only bounds the connect() call; a name
      # that will never resolve blocks inside getaddrinfo before socat's own
      # alarm gets a chance to matter, and connect-timeout does not cover it.
      # Measured directly: with a stale mDNS registration squatting
      # ${guestHost} (see runVm above for why that happens), a
      # single probe hung for minutes, not the 1s the option promised.
      # `timeout` kills the whole process by wall clock regardless of which
      # syscall it is stuck in, which is the only bound that held.
      #
      # A wall-clock deadline (`$SECONDS`) rather than a fixed iteration
      # count, for the same reason: a fixed count of assumed-fast iterations
      # only bounds the total wait if every iteration is fast, which is
      # exactly what a hung probe disproves.
      ready=0
      deadline=$(( SECONDS + ${toString cfg.bootTimeout} ))
      while [ "$SECONDS" -lt "$deadline" ]; do
        if timeout 1 socat -u OPEN:/dev/null TCP:${guestHost}:22,connect-timeout=1 2>/dev/null; then
          ready=1
          break
        fi
        sleep 0.25
      done

      # Fail loudly here rather than fall through to the unbounded connect
      # below. Without this, exhausting the loop above and still trying the
      # real proxy turns "the guest never answered" into the exact hang this
      # whole probe loop exists to prevent -- which is what happened before
      # this check existed: a name that never resolves left `vzrun` blocked
      # indefinitely, and every such call leaked one stuck process here,
      # which in turn kept the idle watchdog in runVm from ever seeing this
      # VM as idle.
      if [ "$ready" -ne 1 ]; then
        echo "vz-builder-connect: ${guestHost}:22 did not answer within ${toString cfg.bootTimeout}s" >&2
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
      #
      # connect-timeout=5 here too, purely as a backstop: the probe loop above
      # already proved ${guestHost} answers, so this should resolve from cache
      # and connect at once. If it does not, this bounds the wait instead of
      # repeating the unbounded hang the probe loop was added to prevent.
      socat STDIO TCP:${guestHost}:22,connect-timeout=5
    '';
  };
in
{
  inherit
    keyDir
    runningFile
    storeDisk
    swapDisk
    restSocket
    guestHost
    authorizedKeysFile
    knownHosts
    vzrun
    runVm
    connect
    ;
}
