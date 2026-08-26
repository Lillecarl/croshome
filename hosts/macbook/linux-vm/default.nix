# A persistent Linux workload VM on Virtualization.framework, started by hand.
#
# A sibling of ../vz-builder on the same stack -- vfkit, direct kernel boot,
# the host store as the overlay's lower layer, keys over their own share,
# NAT plus mDNS -- with three deliberate differences:
#
#  - Persistent. A real root disk that survives restarts, because the point of
#    this machine is stateful workloads (Kubernetes and friends): container
#    images, etcd and logs must outlive the process that hosts them. The
#    builder's recreate-everything-per-start design is exactly wrong here.
#
#  - Started and stopped by hand (`linux-vm start|stop`). It runs as a
#    launchd *user* agent with RunAtLoad and KeepAlive off, so nothing starts
#    it at login and every control verb works without sudo. The builder is a
#    system daemon precisely because builds must be able to summon it; nobody
#    should summon this one by accident, and a VM holding 8 GiB for a cluster
#    nobody is using is the footprint problem the builder's idle watchdog
#    exists to solve -- solved here by simply never leaving it running.
#
#  - Not a builder. No buildMachines entry, no distributed builds, nothing in
#    /etc/nix/machines. The Mac never sends it work; work happens inside it.
#
# Deployment follows the machine: macOS activation SSHes into the guest and
# switches it live when it is running, and skips quietly when it is not --
# the next `linux-vm start` boots straight onto the new configuration either
# way. See ./default.nix's `deploy` for the one wrinkle in the live path.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.virtualisation.linux-vm;
  user = config.system.primaryUser;
  userHome = config.users.users.${user}.home;

  # eval-config rather than lib.nixosSystem, matching ../vz-builder: this
  # module needs nothing but a path to nixpkgs.
  guest = import "${cfg.nixpkgs}/nixos/lib/eval-config.nix" {
    modules = [
      ./guest.nix
      {
        nixpkgs.hostPlatform = "aarch64-linux";

        # Host inheritance, copied from ../vz-builder/default.nix: registry,
        # NIX_PATH, /etc/nixpkgs and experimental features verbatim, so one
        # statement governs both machines and the guest names the same store
        # paths the host resolves.
        nix.registry = config.nix.registry;
        nix.nixPath = config.nix.nixPath;
        environment.etc = lib.optionalAttrs (config.environment.etc ? nixpkgs) {
          nixpkgs.source = config.environment.etc.nixpkgs.source;
        };
        nix.settings.experimental-features = config.nix.settings.experimental-features;

        # Substituters too, which the builder never needed: its store view is
        # refreshed by restarting the VM, while this one can be live-switched
        # onto paths built after it booted -- see `deploy` below -- and that
        # path may mean fetching into the upper layer. The Mac's own caches
        # are the fast way to do that.
        nix.settings.substituters = config.nix.settings.substituters;
        nix.settings.trusted-public-keys = config.nix.settings.trusted-public-keys;
      }
    ]
    ++ cfg.extraModules;
  };

  inherit (guest.config.system.build) kernel initialRamdisk toplevel;

  # Everything the VM owns lives under the user's data directory, because the
  # launchd agent runs as the user and sudo-free control was a design goal.
  # Disk images here are opaque blobs, so the boot volume being
  # case-insensitive costs nothing -- unlike a build scratch, nothing ever
  # creates two names differing only by case inside them.
  stateDir = "${userHome}/.local/share/linux-vm";
  keyShare = "${stateDir}/keys";
  rootDisk = "${stateDir}/root.img";
  swapDisk = "${stateDir}/swap.img";
  consoleLog = "${stateDir}/console.log";

  # The private half of the management keypair, generated on first start and
  # kept here across restarts. Its public half is staged into the guest's key
  # share, so this is what both `linux-vm ssh` and the activation-time deploy
  # authenticate with -- root on the Mac may read it, which is all the deploy
  # needs. The guest is reachable only from this Mac over its NAT.
  activationKey = "${stateDir}/activation_ed25519";

  # vfkit's REST endpoint, as the builder has. Unused by these scripts today;
  # kept because a unix socket in the user's own directory grants nothing a
  # running `linux-vm` does not, and /vm/state beats pgrep for a truthful
  # answer about what the VM is doing. Well inside the 104-byte limit.
  restSocket = "${stateDir}/rest.sock";

  guestHost = "${guest.config.networking.hostName}.local";

  # Same fixed-keypair trick as the builder: the guest installs nixpkgs'
  # shipped host key, so the Mac pins it here and every scripted connection
  # can demand strict checking with no TOFU step.
  knownHosts = pkgs.writeText "linux-vm-known-hosts" ''
    linux-vm ${builtins.readFile "${cfg.nixpkgs}/nixos/modules/profiles/keys/ssh_host_ed25519_key.pub"}
  '';

  # Delivered over the key share at start-up, so changing who may log in does
  # not rebuild the guest.
  authorizedKeysFile = pkgs.writeText "linux-vm-authorized-keys" (
    lib.concatLines cfg.authorizedKeys
  );

  sshOpts = [
    "-i"
    activationKey
    "-o"
    "IdentitiesOnly=yes"
    "-o"
    "BatchMode=yes"
    "-o"
    "HostKeyAlias=linux-vm"
    "-o"
    "UserKnownHostsFile=${knownHosts}"
    "-o"
    "StrictHostKeyChecking=yes"
  ];

  # What runs inside the guest to apply a new configuration. A separate file
  # so the escaping stays readable: everything is literal shell except the
  # baked-in toplevel path, which is the whole point of the file.
  #
  # By the time this runs, the Mac has pushed the new closure's missing paths
  # into the guest's own writable store (`deploy` below), so both steps here
  # are ordinary: nix-env finds the toplevel valid, and switch-to-configuration
  # finds every file it names.
  #
  # switch-to-configuration runs under systemd-run, as upstream nixos-rebuild
  # runs it: a restarted unit takes its process tree down, and this way a
  # restarted sshd cannot cut the switch short.
  remoteDeploy = pkgs.writeText "linux-vm-deploy-remote" ''
    set -euo pipefail
    cur=$(readlink -f /run/current-system || true)
    if [ "$cur" = "${toplevel}" ]; then
      echo "linuxvm: already running the new configuration"
      exit 0
    fi
    echo "linuxvm: switching ''${cur:-<none>} -> ${toplevel}"
    nix-env -p /nix/var/nix/profiles/system --set "${toplevel}"
    systemd-run --collect --pipe --quiet --unit=linux-vm-switch \
      "${toplevel}/bin/switch-to-configuration" switch
  '';

  # Deploy the configuration this Mac system was built with to the guest, if
  # the guest is running. Runs during every macOS activation, and by hand as
  # `linux-vm activate`.
  #
  # Offline means skipped, not failed: the next start boots the new
  # configuration anyway, because the launcher passes the freshly built
  # toplevel on the kernel command line. Reachable-but-failed is different --
  # that leaves a guest claiming to be current while running something else,
  # the invisible staleness that cost the builder real debugging time -- so it
  # exits non-zero and the activation hook turns that into a loud warning
  # rather than failing the whole macOS switch.
  #
  # The gcroots symlink is what pins the guest's closures against host GC: the
  # guest believes its profile protects them, but that register lives in the
  # *guest's* database view, and the host's daemon does not consult it. Only
  # root can write gcroots, so when this runs as the user (linux-vm activate)
  # the link update is skipped and pinning waits for the next activation.
  deploy = pkgs.writeShellApplication {
    name = "linux-vm-deploy";
    runtimeInputs = [
      pkgs.openssh
      pkgs.coreutils
      pkgs.socat
      config.nix.package # `nix copy` into the guest
    ];
    text = ''
      gcroot=/nix/var/nix/gcroots/linux-vm
      if [ "$(readlink "$gcroot" 2>/dev/null)" = "${toplevel}" ]; then
        exit 0
      fi

      # Offline is decided by the port, not by ssh: an unauthenticated guest
      # would also fail the ssh probe, and skipping quietly on an auth bug is
      # exactly how an invisible staleness survives.
      if ! timeout 2 socat -u OPEN:/dev/null TCP:${guestHost}:22,connect-timeout=1 2>/dev/null; then
        echo "linux-vm: guest is offline; its next start boots this configuration" >&2
        exit 0
      fi

      if ! ssh ${lib.concatStringsSep " " sshOpts} \
          root@${guestHost} true 2>/dev/null; then
        echo "linux-vm: guest is up but refused the management key;" >&2
        echo "  live deployment aborted. \`linux-vm restart\` boots onto the new" >&2
        echo "  configuration regardless." >&2
        exit 1
      fi

      # Before copying: hide the Mac's own store lock files, best effort. Nix
      # leaves `<path>.lock` behind when an operation is hard-killed, and
      # through the read-only share such a file appears owned by an unmapped
      # uid with mode 0600 -- the guest cannot open it, and a copy wanting to
      # create a lock of the same name dies with EACCES instead. The unlink
      # here never touches the Mac's file: the overlay records a whiteout in
      # the guest's upper layer, and any flock the Mac holds lives on its
      # inode regardless.
      #
      # It is best effort because vfkit serves the share with this Mac user's
      # privileges, so root-owned ghosts survive it. When the copy below then
      # fails on one, the fix on the Mac is:
      #
      #   sudo find /nix/store -maxdepth 1 -name '*.lock' -delete
      ssh \
        ${lib.concatStringsSep " " sshOpts} \
        root@${guestHost} \
        "find /nix/store -maxdepth 1 -name '*.lock' -delete" > /dev/null 2>&1 || true

      # Push the closure's missing paths into the guest's own writable store
      # before switching. The overlay makes the *files* of new lower-layer
      # paths visible immediately, but the guest's view of the lower store's
      # *database* froze at boot -- the daemon opens it SQLite-immutable, and
      # recent host builds sit un-checkpointed in the WAL besides -- so a path
      # built after this VM booted reads as invalid no matter how the daemon
      # feels about reopening it. Copying the delta registers those paths in a
      # database this VM owns and never freezes; the delta is small by
      # construction, since everything the guest already had is skipped.
      #
      # The host is the ssh_config alias below, which carries the pinned key
      # and host key; nothing here repeats them.
      nix copy --to ssh://linux-vm "${toplevel}"

      if ssh ${lib.concatStringsSep " " sshOpts} \
          root@${guestHost} bash -s < ${remoteDeploy}; then
        ln -sfn "${toplevel}" "$gcroot" 2>/dev/null || true
      else
        echo "linux-vm: live deployment FAILED; the guest is still running its old" >&2
        echo "  configuration. Fix the cause, rerun \`linux-vm activate\`, or just" >&2
        echo "  \`linux-vm restart\` to boot onto the new one." >&2
        exit 1
      fi
    '';
  };

  runVm = pkgs.writeShellApplication {
    name = "linux-vm-run";
    runtimeInputs = [
      pkgs.vfkit
      pkgs.coreutils
      pkgs.openssh # ssh-keygen
    ];
    text = ''
      install -d -m 0755 ${lib.escapeShellArg stateDir} ${lib.escapeShellArg keyShare}

      # One management keypair, generated once and kept. Staged below with any
      # configured extra keys.
      if [ ! -f ${lib.escapeShellArg activationKey} ]; then
        ssh-keygen -q -t ed25519 -N "" -C linux-vm-activation \
          -f ${lib.escapeShellArg activationKey}
      fi
      {
        cat "${activationKey}.pub"
        cat ${authorizedKeysFile}
      } > ${keyShare}/authorized_keys
      chmod 0644 ${keyShare}/authorized_keys

      # Created only when absent -- this is the line that makes the machine
      # persistent rather than recreated per start. Both images are sparse, so
      # sizing them generously costs nothing until the guest writes.
      [ -e ${rootDisk} ] || truncate -s ${toString cfg.diskSize}M ${rootDisk}
      [ -e ${swapDisk} ] || truncate -s ${toString cfg.swapSize}M ${swapDisk}

      # Which configuration to boot: the gcroots pin when one exists, else the
      # closure this script was built with. The pin is written only after a
      # fully successful live deployment, which makes it the boot source of
      # truth twice over -- it keeps the closure alive against host GC, and it
      # means a failed or interrupted deploy can never brick the next start:
      # the VM boots the last configuration known complete in its store, and
      # the next deploy retries the difference. A fresh start needs none of
      # this -- its daemon opens the lower store's database anew, so it sees
      # everything the Mac has built -- which is what makes the fallback safe.
      top=$(readlink /nix/var/nix/gcroots/linux-vm 2>/dev/null || true)
      if [ ! -d "$top" ]; then
        top="${toplevel}"
      fi

      rm -f ${lib.escapeShellArg restSocket}

      # Rosetta has to be present on the host; without it the VM still boots
      # and runs arm64 images, it just cannot run x86_64 ones.
      rosetta=()
      if [ -d /Library/Apple/usr/libexec/oah ]; then
        rosetta=(--device "rosetta,mountTag=rosetta")
      else
        echo "linux-vm: Rosetta is not installed; x86_64 containers will not run" >&2
      fi

      # Root first so it is /dev/vda, swap second for /dev/vdb -- the guest's
      # fstab hardcodes that order.
      vfkit \
        --cpus ${toString cfg.cores} \
        --memory ${toString cfg.memory} \
        --bootloader "linux,kernel=${kernel}/Image,initrd=${initialRamdisk}/initrd,cmdline=\"console=hvc0 systemConfig=$top init=$top/init\"" \
        --device virtio-rng \
        --device "virtio-net,nat" \
        --device "virtio-fs,sharedDir=${keyShare},mountTag=keys" \
        --device "virtio-blk,path=${rootDisk}" \
        --device "virtio-blk,path=${swapDisk}" \
        "''${rosetta[@]}" \
        --device "virtio-fs,sharedDir=/nix,mountTag=hostnix" \
        --restful-uri "unix://${restSocket}" \
        --device "virtio-serial,logFilePath=${consoleLog}" &
      vm=$!

      trap 'rm -f ${restSocket}' EXIT
      wait "$vm" 2>/dev/null || true
    '';
  };

  cli = pkgs.writeShellApplication {
    name = "linux-vm";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssh
      pkgs.socat
    ];
    text = ''
      label=org.nixos.linux-vm
      uid=$(id -u)

      usage() {
        echo "usage: linux-vm [start|stop|restart|status|ssh|console|activate]" >&2
        exit 2
      }

      vm_pid() {
        pgrep -f "vfkit.*${stateDir}" || true
      }

      # Wait until the guest answers on port 22, bounded by wall clock like
      # the builder's connect handler: a hung name resolution must time out
      # too, which socat's own connect-timeout alone does not cover.
      await_guest() {
        deadline=$(( SECONDS + ${toString cfg.bootTimeout} ))
        while [ "$SECONDS" -lt "$deadline" ]; do
          if timeout 1 socat -u OPEN:/dev/null TCP:${guestHost}:22,connect-timeout=1 2>/dev/null; then
            return 0
          fi
          sleep 1
        done
        return 1
      }

      case ''${1-} in
        start)
          if [ -n "$(vm_pid)" ]; then
            echo "linux-vm: already running (pid $(vm_pid))"
            exit 0
          fi
          echo "starting linux-vm..."
          /bin/launchctl kickstart "gui/$uid/$label"
          if await_guest; then
            echo "linux-vm: up at ${guestHost} (\`linux-vm ssh\` to log in)"
          else
            echo "linux-vm: guest did not answer within ${toString cfg.bootTimeout}s;" >&2
            echo "  \`linux-vm console\` shows what the guest has said so far." >&2
            exit 1
          fi
          ;;
        stop)
          pid=$(vm_pid)
          if [ -z "$pid" ]; then
            echo "linux-vm: not running"
            exit 0
          fi
          echo "requesting poweroff from the guest..."
          # There is no ACPI to answer a hypervisor power button -- direct
          # kernel boot provides none, the same fact that makes the builder's
          # idle shutdown a hard stop -- so graceful means asking systemd.
          timeout 8 ssh ${lib.concatStringsSep " " sshOpts} \
            root@${guestHost} systemctl poweroff > /dev/null 2>&1 \
            || echo "linux-vm: guest did not answer; forcing"
          deadline=$(( SECONDS + 90 ))
          while kill -0 "$pid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do
            sleep 2
          done
          if kill -0 "$pid" 2>/dev/null; then
            echo "linux-vm: guest still up after 90s; killing vfkit (hard stop)"
            kill "$pid" 2>/dev/null || true
            sleep 5
            kill -9 "$pid" 2>/dev/null || true
          fi
          echo "linux-vm: stopped"
          ;;
        restart)
          "$0" stop
          "$0" start
          ;;
        status)
          state=$(/bin/launchctl print "gui/$uid/$label" 2>/dev/null |
            awk '/^[[:space:]]*state = / {print $3; exit}')
          echo "agent: ''${state:-not loaded}"
          pid=$(vm_pid)
          if [ -z "$pid" ]; then
            echo "vm: stopped"
            exit 0
          fi
          echo "vm: running (pid $pid)"
          if timeout 5 ssh ${lib.concatStringsSep " " sshOpts} \
              root@${guestHost} true 2>/dev/null; then
            cur=$(ssh ${lib.concatStringsSep " " sshOpts} \
              root@${guestHost} readlink -f /run/current-system 2>/dev/null || true)
            if [ "$cur" = "${toplevel}" ]; then
              echo "guest: reachable, up to date"
            else
              echo "guest: reachable, running an older configuration"
              echo "       (\`linux-vm activate\` to switch live, or \`linux-vm restart\`)"
            fi
          else
            echo "guest: not answering yet"
          fi
          ;;
        ssh)
          shift
          exec ssh ${lib.concatStringsSep " " sshOpts} root@${guestHost} "$@"
          ;;
        console)
          if [ ! -f ${consoleLog} ]; then
            echo "linux-vm: never started; no console log yet" >&2
            exit 1
          fi
          exec tail -n 200 -F ${consoleLog}
          ;;
        activate)
          exec ${lib.getExe deploy}
          ;;
        *)
          usage
          ;;
      esac
    '';
  };
in
{
  options.virtualisation.linux-vm = {
    enable = lib.mkEnableOption "a persistent Linux workload VM under Virtualization.framework";

    nixpkgs = lib.mkOption {
      type = lib.types.path;
      default = pkgs.path;
      defaultText = lib.literalExpression "pkgs.path";
      description = ''
        The nixpkgs used to build the guest. Defaults to the one this system
        is built from, so the two cannot drift.
      '';
    };

    extraModules = lib.mkOption {
      type = lib.types.listOf lib.types.deferredModule;
      default = [ ];
      example = lib.literalExpression ''
        [ { services.k3s.enable = true; } ]
      '';
      description = ''
        Extra NixOS modules merged into the guest. This is how workload
        software arrives: a Kubernetes distribution, a container runtime,
        monitoring -- anything the guest should run belongs here or in
        ./guest.nix, never in a hand-run provisioning script.
      '';
    };

    cores = lib.mkOption {
      type = lib.types.int;
      default = 4;
      description = ''
        vCPUs given to the guest. Not "every core" like the builder: this VM
        coexists with the Mac for days at a time, and a persistent neighbour
        holding all fifteen cores would make every interactive thing stutter.
      '';
    };

    memory = lib.mkOption {
      type = lib.types.int;
      default = 8192;
      description = ''
        Guest RAM in MiB. Virtualization.framework backs this lazily, so an
        idle guest costs little -- but whatever it has touched it keeps until
        the VM exits, which is why stopping it when done matters more here
        than for the builder.
      '';
    };

    diskSize = lib.mkOption {
      type = lib.types.int;
      default = 262144; # 256 GiB
      description = ''
        Size in MiB of the persistent root disk. Sparse on the host, so this
        is a ceiling, not a reservation; size it against free space on the
        APFS volume holding $HOME. Changing it does nothing to an existing
        image -- resize the filesystem inside the guest instead.
      '';
    };

    swapSize = lib.mkOption {
      type = lib.types.int;
      default = cfg.memory;
      defaultText = lib.literalExpression "memory";
      description = ''
        Size in MiB of the persistent swap disk, or 0 for none. Equal to
        `memory`: this machine holds state worth spilling for, unlike the
        builder, whose swap exists only to turn an OOM into a slow build.
      '';
    };

    bootTimeout = lib.mkOption {
      type = lib.types.int;
      default = 180;
      description = ''
        Seconds for `linux-vm start` to wait for the guest to answer on port
        22. Generous because the first ever boot formats the root disk in
        stage 1.
      '';
    };

    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = lib.literalExpression ''[ "ssh-ed25519 AAAAC3Nz... you@mac" ]'';
      description = ''
        Extra public keys that may log into the guest, staged alongside the
        management key at every start. All of them land in one global
        authorized_keys, so any of them logs in as root -- single-tenant
        machine on a host-only NAT, and the management key is already root.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      cli
      runVm # the launchd agent runs this from /run/current-system/sw/bin
    ];

    # A user agent, deliberately: kickstart/bootout in the gui domain need no
    # sudo, RunAtLoad=false means login never summons a VM, and KeepAlive=
    # false means a crash stays a crash instead of resurrecting under your
    # feet.
    #
    # The stable /run/current-system path, not a store path: a plist naming a
    # store output changes on every rebuild, and relaunching a changed agent
    # kills whatever it was hosting -- which for this machine means pulling
    # the power on a stateful guest in the middle of an ordinary ai-rebuild.
    # This plist is byte-identical across rebuilds, so activation has nothing
    # to bounce, and /run/current-system moves underneath it. Same reasoning
    # as the ai-rebuild sudo rules naming sw/bin paths.
    launchd.user.agents.linux-vm = {
      serviceConfig = {
        ProgramArguments = [
          "/bin/sh"
          "-c"
          "exec /run/current-system/sw/bin/linux-vm-run"
        ];
        RunAtLoad = false;
        KeepAlive = false;
        # Logging to ~/Library/Logs because launchd opens StandardErrorPath
        # before the agent runs -- the state directory does not exist yet at
        # that moment, and ~/Library/Logs always does.
        StandardErrorPath = "${userHome}/Library/Logs/linux-vm.log";
      };
    };

    # `ssh linux-vm` works from any shell, with the same pinned host key the
    # scripts use.
    environment.etc."ssh/ssh_config.d/102-linux-vm.conf".text = ''
      Host linux-vm
        User root
        Hostname ${guestHost}
        HostKeyAlias linux-vm
        IdentityFile ${activationKey}
        UserKnownHostsFile ${knownHosts}
        StrictHostKeyChecking yes
    '';

    # Live-deploy to the guest on every macOS activation, online or skip.
    # extraActivation rather than postActivation because ../vz-builder owns
    # postActivation outright (plain assignment, not a merge); this slot is
    # free and runs a moment earlier, which orders fine -- the two hooks
    # concern different virtual machines.
    system.activationScripts.extraActivation.text = ''
      if ! ${lib.getExe deploy}; then
        echo "" >&2
        echo "*************************************************************" >&2
        echo "* WARNING: the Linux VM is running but did not take the new *" >&2
        echo "* configuration. See the linux-vm lines above for the fix.  *" >&2
        echo "*************************************************************" >&2
      fi
    '';
  };
}
