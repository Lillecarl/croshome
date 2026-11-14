# dynhetz's pynixd as this machine's build machine and first substituter.
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
  uri = "ssh-ng://hetztop@dynhetz.ch.se.eu.org:2234";
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

  nix.settings = {
    # Fetch inputs on dynhetz too, rather than download them here first.
    builders-use-substitutes = true;
    # `trusted=1`: pynixd does not sign, and an admin client of it is as
    # trusted as this daemon's own builds. Priority 2 asks dynhetz before
    # cache.nixos.org (40).
    extra-substituters = [
      "${uri}?ssh-key=${sshKey}&base64-ssh-public-host-key=${hostKey}&trusted=1&priority=2"
    ];
  };
}
