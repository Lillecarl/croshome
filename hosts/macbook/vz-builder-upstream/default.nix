# The upstream Virtualization.framework builder (pkgs.darwin.linux-builder-vz,
# driven by vzvm), run on demand beside our own host-store one.
#
# Upstream ships this as an always-on `nix.linux-builder` daemon. vzvm binds the
# client port itself -- its VsockProxy owns the listening socket and splices it
# to guest vsock -- so launchd cannot also own that port. To wake the VM on the
# first connection, launchd listens on a public port here, and vzlink drives it
# exactly as it drives our builder: vzlink-proxy per connection,
# vzlink-supervisor for readiness, connection counting and idle stop. See
# ../vz-builder/vzlink.nix and ../vz-builder/vzlink-guest.nix.
#
# Unlike ours this guest's store is its own -- an erofs image of its closure
# plus a persistent disk -- so it works on a case-insensitive /nix: the image
# is built from host-store files with the case-hack suffixes stripped
# (nixos/lib/erofs-store-image.nix). The persistent disk is also its root.
#
# The two builders coexist because they touch nothing in common: different
# ports, host names, ssh host aliases and state directories. They do share the
# builder key at /etc/nix/builder_ed25519, which is fine -- each guest is
# authorised with the same public half.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nix.linux-builder-vz;

  keysDir = "${cfg.stateDir}/keys";
  runningFile = "${cfg.stateDir}/running";

  vzlink = import ../vz-builder/vzlink.nix { inherit lib pkgs; };

  # Upstream's nix-builder.nix profile, with our overrides. The package's only
  # argument is the extra module list.
  guest =
    (pkgs.darwin.linux-builder-vz.override {
      modules = [
        ../vz-builder/vzlink-guest.nix
        (
          { config, ... }:
          {
            # The readiness agent from ./vzlink-guest.nix, reached like sshd.
            virtualisation.vz.forwardPorts = [
              {
                host.port = cfg.readinessPort;
                guest.port = config.virtualisation.vzlink.readinessVsockPort;
              }
            ];

            # The root on the persistent disk, not upstream's tmpfs: a tmpfs
            # holds everything written outside the store in guest RAM, which
            # is host RAM the VM never returns. It also keeps the Nix
            # database (/nix/var) on the same disk as the store layer it
            # describes; on a tmpfs root the database forgot every path the
            # persistent layer held at each boot.
            #
            # mkOverride 9 because upstream sets both with mkVMOverride (10),
            # which beats mkForce. Barriers stay on: unlike ./vz-builder's,
            # this disk outlives a crash of the Mac.
            fileSystems."/" = lib.mkOverride 9 {
              device = "/dev/vdb";
              fsType = "ext4";
              autoFormat = true;
              neededForBoot = true;
              options = [ "noatime" ];
            };
            fileSystems."/nix/.rw-store" = lib.mkOverride 9 {
              enable = false;
              device = "none";
              fsType = "tmpfs";
            };
            # A new file, because the disk upstream names after the host
            # holds the store layer at its top level, not a root.
            virtualisation.vz.diskImage = lib.mkForce "./${config.networking.hostName}-root.img";
            # The root persists, so /tmp would too.
            boot.tmp.cleanOnBoot = true;
          }
        )
        {
          networking.hostName = "vzvm-builder";

          virtualisation.darwin-builder = {
            hostPort = cfg.internalPort;
            inherit (cfg) memorySize diskSize;
          };
          virtualisation.cores = cfg.cores;

          virtualisation.vz = {
            inherit (cfg) nestedVirtualization;
            console = "file";
            consoleLog = "${cfg.stateDir}/console.log";
          };

          # A real host path (created at VM start), not upstream's `$KEYS`
          # shell indirection: the profile passes the guest's keys through
          # create-builder's environment, which we do not use.
          virtualisation.sharedDirectories.keys.source = lib.mkForce keysDir;
          # Drops the second share upstream adds for host CA certs, whose
          # source is another shell expression.
          virtualisation.useHostCerts = lib.mkForce false;
        }
      ];
    }).nixosConfig;

  vm = guest.system.build.vm;

  # The fixed host key nixpkgs ships for its builder VM, the same one our
  # builder trusts. HostKeyAlias keeps the two entries apart.
  publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUpCV2N4Yi9CbGFxdDFhdU90RStGOFFVV3JVb3RpQzVxQkorVXVFV2RWQ2Igcm9vdEBuaXhvcwo=";

  # Upstream's run script ends in `exec vzvm`, so $vm is the vzvm process
  # once it is running. Before that the same script builds the erofs store
  # image when it is missing -- see `prewarm` below, which normally has.
  runVm = pkgs.writeShellApplication {
    name = "vzvm-builder-vm";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      mkdir -p ${lib.escapeShellArg keysDir}
      install -m 0444 ${lib.escapeShellArg "${cfg.builderKey}.pub"} ${lib.escapeShellArg keysDir}/builder_ed25519.pub

      # The run script resolves images against $PWD; this is the launcher's
      # only role on that front.
      cd ${lib.escapeShellArg cfg.stateDir}
      exec 2>>${lib.escapeShellArg "${cfg.stateDir}/vm.log"}

      # Upstream deletes stale store images only right after building a new
      # one, and the pre-warm usually builds it, so that never ran. No VM
      # runs while this launcher does, so no image is in use.
      if [ -f ${storeImageName} ]; then
        find . -maxdepth 1 -name 'store-*.img' ! -name ${storeImageName} -delete
      fi

      ${lib.getExe vm} &
      vm=$!

      ${vzlink.supervise {
        inherit (cfg)
          stateDir
          internalPort
          readinessPort
          bootTimeout
          idleTimeout
          stopMode
          ;
        inherit runningFile;
        inherit (guest.system.build) toplevel;
      }}
    '';
  };

  connect = vzlink.connect {
    name = "vzvm-builder-connect";
    inherit (cfg)
      stateDir
      internalPort
      bootTimeout
      daemonName
      ;
  };

  # The erofs store image, built ahead of the first boot. Upstream builds it
  # in the run script because a derivation would need the Linux builder this
  # VM is (vz-vm.nix says so); building it on the host at runtime is the
  # same choice, made earlier. Activation only kicks this job, so a switch
  # never waits for it or fails on it, and the run script still builds the
  # image itself when this has not finished or has failed.
  #
  # The name must match upstream's storeImageName (vz-vm.nix), or the run
  # script will not find the image and builds its own: same closureInfo,
  # same name rule. Never deletes old images; the run script does that, and
  # a running VM may still be using one.
  storeClosureInfo = pkgs.closureInfo {
    rootPaths = [
      guest.system.build.toplevel
      (pkgs.closureInfo { rootPaths = guest.virtualisation.additionalPaths; })
    ];
  };
  storeImageName = "store-${lib.head (lib.splitString "-" (baseNameOf (toString storeClosureInfo)))}.img";
  prewarm = pkgs.writeShellScript "vzvm-builder-prewarm" ''
    set -eu
    image=${lib.escapeShellArg "${cfg.stateDir}/${storeImageName}"}
    if [ -f "$image" ]; then
      echo "$(date) store image present: $image"
      exit 0
    fi
    tmp="$image.tmp.prewarm"
    trap 'rm -f "$tmp"' EXIT
    echo "$(date) building $image"
    ${import "${pkgs.path}/nixos/lib/erofs-store-image.nix" {
      hostPkgs = pkgs;
      storePaths = "${storeClosureInfo}/store-paths";
      label = "nix-store";
      destination = ''"$tmp"'';
    }}
    mv "$tmp" "$image"
    trap - EXIT
    echo "$(date) built $image"
  '';
in
{
  options.nix.linux-builder-vz = {
    enable = lib.mkEnableOption "the upstream vzvm Linux builder, started on demand";

    hostName = lib.mkOption {
      type = lib.types.str;
      default = "linux-builder-vz";
      description = "Host alias for ssh and the build machine entry.";
    };

    publicPort = lib.mkOption {
      type = lib.types.port;
      default = 31023;
      description = "Loopback port launchd listens on. Connecting to it wakes the VM.";
    };

    internalPort = lib.mkOption {
      type = lib.types.port;
      default = 31024;
      description = "Loopback port vzvm itself binds, behind the launchd listener.";
    };

    memorySize = lib.mkOption {
      type = lib.types.int;
      default = 8192;
      description = "Guest RAM in MiB.";
    };

    cores = lib.mkOption {
      type = lib.types.int;
      default = 8;
      description = "Guest vCPUs.";
    };

    diskSize = lib.mkOption {
      type = lib.types.int;
      default = 20480;
      description = "Persistent store disk in MiB.";
    };

    maxJobs = lib.mkOption {
      type = lib.types.int;
      default = 4;
      description = "Derivations Nix runs on this builder at once.";
    };

    nestedVirtualization = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Boot at EL2 for a working /dev/kvm. macOS 15+, M3 or newer.";
    };

    builderKey = lib.mkOption {
      type = lib.types.str;
      default = "/etc/nix/builder_ed25519";
      description = "Private key the host uses to log into the guest; public half beside it.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/vzvm-builder";
      description = "Host directory for the VM images, console logs and key share.";
    };

    idleTimeout = lib.mkOption {
      type = lib.types.int;
      default = 60;
      description = "Seconds without a connection before the VM shuts down.";
    };

    bootTimeout = lib.mkOption {
      type = lib.types.int;
      default = 120;
      description = ''
        Seconds a connection waits for the guest to serve after a wakeup. It
        covers building the store image in the rare start the pre-warm job
        has not done it for.
      '';
    };

    readinessPort = lib.mkOption {
      type = lib.types.port;
      default = 31025;
      description = "Loopback port vzvm forwards to the guest's readiness agent.";
    };

    stopMode = lib.mkOption {
      type = lib.types.enum [
        "graceful"
        "kill"
      ];
      default = "graceful";
      description = ''
        How the supervisor stops the VM. `graceful`, because this guest's
        disk persists: vzvm turns SIGTERM into a guest power-off, and the
        supervisor kills only after 30s.
      '';
    };

    daemonName = lib.mkOption {
      type = lib.types.str;
      default = "vzvm-builder-vm";
      description = "Launchd daemon that runs the VM, label org.nixos.<name>.";
    };

    socketName = lib.mkOption {
      type = lib.types.str;
      default = "vzvm-builder";
      description = "Launchd socket daemon that fronts the public port.";
    };
  };

  config = lib.mkIf cfg.enable {
    system.activationScripts.preActivation.text = ''
      mkdir -p ${lib.escapeShellArg cfg.stateDir}
    '';

    # Stop a VM running a guest this configuration no longer describes, so
    # the next build boots the new one; then start the image pre-warm. Both
    # are best effort: a failure here warns and never fails the switch.
    system.activationScripts.postActivation.text = ''
      running=${lib.escapeShellArg runningFile}
      if [ -e "$running" ]; then
        gen=$(head -1 "$running")
        pid=$(sed -n 2p "$running")
        if [ "$gen" != ${lib.escapeShellArg guest.system.build.toplevel} ]; then
          echo "vzvm-builder: guest changed, stopping the stale VM (pid $pid)"
          kill "$pid" 2>/dev/null || true
        fi
      fi
      /bin/launchctl kickstart system/org.nixos.${cfg.daemonName}-prewarm 2>/dev/null \
        || echo "vzvm-builder: could not start the store image pre-warm; the next boot builds it" >&2
    '';

    launchd.daemons."${cfg.daemonName}-prewarm".serviceConfig = {
      ProgramArguments = [ "${prewarm}" ];
      RunAtLoad = false;
      KeepAlive = false;
      StandardOutPath = "${cfg.stateDir}/prewarm.log";
      StandardErrorPath = "${cfg.stateDir}/prewarm.log";
    };

    launchd.daemons.${cfg.daemonName} = {
      script = "exec ${lib.getExe runVm}";
      serviceConfig = {
        RunAtLoad = false;
        KeepAlive = false;
        WorkingDirectory = cfg.stateDir;
      };
    };

    launchd.daemons.${cfg.socketName} = {
      serviceConfig = {
        ProgramArguments = [ (lib.getExe connect) ];
        Sockets.Listener = {
          SockNodeName = "127.0.0.1";
          SockServiceName = toString cfg.publicPort;
          SockFamily = "IPv4";
          SockProtocol = "TCP";
        };
        inetdCompatibility.Wait = false;
        StandardErrorPath = "${cfg.stateDir}/connect.log";
      };
    };

    environment.etc."ssh/ssh_config.d/102-linux-builder-vz.conf".text = ''
      Host ${cfg.hostName}
        User builder
        Hostname 127.0.0.1
        Port ${toString cfg.publicPort}
        HostKeyAlias ${cfg.hostName}
        IdentityFile ${cfg.builderKey}
        Ciphers ${lib.concatStringsSep "," guest.services.openssh.settings.Ciphers}
    '';

    nix.distributedBuilds = true;

    nix.buildMachines = [
      {
        hostName = cfg.hostName;
        sshUser = "builder";
        sshKey = cfg.builderKey;
        protocol = "ssh-ng";
        inherit publicHostKey;
        systems = [
          "aarch64-linux"
          "x86_64-linux" # via Rosetta
        ];
        maxJobs = cfg.maxJobs;
        speedFactor = 2;
        supportedFeatures = [
          "big-parallel"
          "benchmark"
        ]
        ++ lib.optional cfg.nestedVirtualization "kvm";
      }
    ];

    nix.settings.builders-use-substitutes = true;
  };
}
