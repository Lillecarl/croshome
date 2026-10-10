# The host half of vzlink, shared by ./vm.nix and ../vz-builder-upstream: the
# launchd connection handler, and the shell that hands a started VM to the
# supervisor. The guest half is ./vzlink-guest.nix.
{ lib, pkgs }:
let
  controlSock = stateDir: "${stateDir}/vzlink-control.sock";
in
{
  /**
    launchd's per-connection handler: vzlink-proxy kickstarts the VM, waits
    for the supervisor to report the guest serving (bounded by `bootTimeout`,
    so a guest that never boots fails the build instead of hanging it),
    registers the connection, and moves bytes.
  */
  connect =
    {
      name,
      stateDir,
      internalPort,
      bootTimeout,
      daemonName,
    }:
    pkgs.writeShellApplication {
      inherit name;
      text = ''
        exec ${lib.getExe' pkgs.vzlink "vzlink-proxy"} \
          --control-sock ${lib.escapeShellArg (controlSock stateDir)} \
          --internal-port ${toString internalPort} \
          --boot-timeout ${toString bootTimeout} \
          --daemon-label org.nixos.${daemonName}
      '';
    };

  /**
    Shell that records the running VM and execs the supervisor. `$vm` must
    hold vzvm's pid, started in the background by the same script.

    exec keeps the pid, so vzvm stays the supervisor's child and the
    supervisor reaps it. The supervisor answers the proxies' readiness asks,
    counts their registered connections, and stops the VM after
    `idleTimeout` without one, the way `stopMode` says.
  */
  supervise =
    {
      stateDir,
      internalPort,
      readinessPort,
      bootTimeout,
      idleTimeout,
      stopMode,
      runningFile,
      toplevel,
      vzvmConfig ? null,
    }:
    ''
      # Recorded for the activation check that stops a stale VM, and removed
      # by the supervisor on the way out so a dead VM never looks live.
      printf '%s\n%s\n' ${lib.escapeShellArg toplevel} "$vm" > ${lib.escapeShellArg runningFile}

      exec ${lib.getExe' pkgs.vzlink "vzlink-supervisor"} \
        --stop-mode ${stopMode} \
        --state-dir ${lib.escapeShellArg stateDir} \
        --control-sock ${lib.escapeShellArg (controlSock stateDir)} \
        --internal-port ${toString internalPort} \
        --readiness-port ${toString readinessPort} \
        --boot-timeout ${toString bootTimeout} \
        --idle-timeout ${toString idleTimeout} \
        --vm-pid "$vm" \
        --running-file ${lib.escapeShellArg runningFile}${
          lib.optionalString (vzvmConfig != null) " \\\n  --vzvm-config ${vzvmConfig}"
        }
    '';
}
