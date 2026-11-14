# dynhetz's pynixd as this machine's build machine.
#
# The daemon logs in with this machine's SSH host key, which dynhetz admits as
# an admin client (../dynhetz/pynixd.nix). The host key is there from the first
# boot, so the first switch to this file already builds remotely.
#
# Same shape as nixidae's CI runners (.github/workflows/*-tests.yml there).
{ ... }:
let
  # The pynixd listener, not sshd: port 2234, with pynixd's own host key
  # (/var/lib/pynixd-ssh/ssh_host_ed25519_key.pub on dynhetz), base64-encoded.
  hostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUF0R0xKdjVSanpVdU9HV25zYVRSRXNuQWo2eFZwcEFuZWdhWFdma0pISGw=";
  sshKey = "/etc/ssh/ssh_host_ed25519_key";
in
{
  nix.distributedBuilds = true;
  nix.buildMachines = [
    {
      hostName = "dynhetz.ch.se.eu.org:2234";
      sshUser = "hetztop";
      protocol = "ssh-ng";
      system = "x86_64-linux";
      inherit sshKey;
      publicHostKey = hostKey;
      maxJobs = 16;
      speedFactor = 4;
      supportedFeatures = [
        "benchmark"
        "big-parallel"
      ];
    }
  ];

  # Fetch inputs on dynhetz too, rather than download them here first.
  nix.settings.builders-use-substitutes = true;

  # Not a substituter yet. This daemon (Nix 2.34) sends QueryRealisation in
  # the old shape, pynixd refuses it, and Nix 2.34 aborts on that error reply
  # (same root as nixidae/nixidae#1061). Once pynixd answers it, add
  #   nix.settings.extra-substituters = [ "ssh-ng://hetztop@dynhetz.ch.se.eu.org:2234?ssh-key=${sshKey}&base64-ssh-public-host-key=${hostKey}&trusted=1&priority=2" ];
  # `trusted=1` because pynixd does not sign; priority 2 asks it before
  # cache.nixos.org (40).
}
