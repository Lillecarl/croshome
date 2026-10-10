# The guest half of vzlink, for any builder guest the host drives with
# vzlink-proxy and vzlink-supervisor: ./guest.nix and the upstream vzvm
# guest in ../vz-builder-upstream. The host half is ./vzlink.nix.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.virtualisation.vzlink;
in
{
  options.virtualisation.vzlink.readinessVsockPort = lib.mkOption {
    type = lib.types.port;
    default = 11123;
    description = ''
      vsock port `vzlink-guest` answers readiness on. The host module reads
      it from the evaluated guest to forward its `readinessPort`, so the two
      cannot drift.
    '';
  };

  config = {
    # Tells the host supervisor whether nix-daemon serves, so a slow boot
    # names its missing stage instead of timing out on the SSH banner. The
    # supervisor waits on it before anything connects: if it never answers,
    # every connection fails with "builder not ready" and the reason it
    # last gave. Nothing in the guest's own boot waits on it.
    #
    # Socket-activated: systemd listens from sockets.target, before sshd
    # answers, so the host's first probe waits for Python to start instead
    # of reaching a closed port. vzvm retries a closed vsock port on its own
    # schedule, and that cost 1.4s of every boot.
    systemd.sockets.vzlink-guest = {
      wantedBy = [ "sockets.target" ];
      listenStreams = [ "vsock::${toString cfg.readinessVsockPort}" ];
    };
    # Started at boot as well, not only on the first probe: Python takes
    # ~0.25s to start, and that is better spent before the host asks.
    systemd.services.vzlink-guest = {
      description = "Answer the host's builder readiness probes over vsock";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = lib.escapeShellArgs [
          (lib.getExe' (pkgs.python3.pkgs.callPackage ../../../pkgs/vzlink { }) "vzlink-guest")
          "--vsock-port"
          (toString cfg.readinessVsockPort)
        ];
        DynamicUser = true;
        Restart = "always";
        RestartSec = 1;
      };
    };

    # AES-GCM only: both ends are Apple Silicon and run it on the ARMv8
    # crypto instructions, where OpenSSH's default ChaCha20-Poly1305 is
    # software. Every client is ours, and the host module reads this list
    # for them, so no fallback is needed.
    services.openssh.settings.Ciphers = [ "aes128-gcm@openssh.com" ];
  };
}
