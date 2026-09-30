# The upstream Virtualization.framework builder (pkgs.darwin.linux-builder-vz,
# driven by vzvm), run on demand beside our own host-store one.
#
# Upstream ships this as an always-on `nix.linux-builder` daemon. vzvm binds the
# client port itself -- its VsockProxy owns the listening socket and splices it
# to guest vsock -- so launchd cannot also own that port. To wake the VM on the
# first connection, launchd listens on a public port here and a handler starts
# the VM and proxies to vzvm's internal port: the same shape as our builder.
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

  # Counts a live connection by the same handler name the idle loop greps for.
  connectName = "vzvm-builder-connect";

  # Upstream's nix-builder.nix profile, with our overrides. The package's only
  # argument is the extra module list.
  guest =
    (pkgs.darwin.linux-builder-vz.override {
      modules = [
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

  # Runs the guest, and stops it once no handler is connected. vzvm is exec'd
  # in place by the run script, so $vm is the vzvm process.
  runVm = pkgs.writeShellApplication {
    name = "vzvm-builder-vm";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.procps
    ];
    text = ''
      mkdir -p ${lib.escapeShellArg keysDir}
      install -m 0444 ${lib.escapeShellArg "${cfg.builderKey}.pub"} ${lib.escapeShellArg keysDir}/builder_ed25519.pub

      # The run script resolves images against $PWD; this is the launcher's
      # only role on that front.
      cd ${lib.escapeShellArg cfg.stateDir}
      exec 2>>${lib.escapeShellArg "${cfg.stateDir}/vm.log"}
      ${lib.getExe vm} &
      vm=$!
      trap 'kill $vm 2>/dev/null || true' EXIT

      idle=0
      while kill -0 $vm 2>/dev/null; do
        sleep 15
        if pgrep -f ${connectName} >/dev/null; then
          idle=0
        else
          idle=$((idle + 15))
          if [ "$idle" -ge ${toString cfg.idleTimeout} ]; then
            echo "vzvm-builder: idle for ${toString cfg.idleTimeout}s, shutting down" >&2
            kill $vm 2>/dev/null || true
            break
          fi
        fi
      done
      wait $vm 2>/dev/null || true
    '';
  };

  connect = pkgs.writeShellApplication {
    name = connectName;
    runtimeInputs = [
      pkgs.socat
      pkgs.coreutils
    ];
    text = ''
      /bin/launchctl kickstart system/org.nixos.${cfg.daemonName} 2>/dev/null || true

      # Wait for vzvm's listener, not for the guest: vzvm holds a connection
      # until the guest is up, so the copy below is the wait.
      ready=0
      deadline=$(( SECONDS + ${toString cfg.bootTimeout} ))
      while [ "$SECONDS" -lt "$deadline" ]; do
        if timeout 1 socat -u OPEN:/dev/null TCP:127.0.0.1:${toString cfg.internalPort},connect-timeout=1 2>/dev/null; then
          ready=1
          break
        fi
        sleep 0.25
      done
      if [ "$ready" -ne 1 ]; then
        echo "vzvm-builder-connect: 127.0.0.1:${toString cfg.internalPort} did not answer within ${toString cfg.bootTimeout}s" >&2
        exit 1
      fi

      socat STDIO TCP:127.0.0.1:${toString cfg.internalPort},connect-timeout=5
    '';
  };
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
      description = "Seconds to wait for vzvm to listen after a wakeup.";
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
