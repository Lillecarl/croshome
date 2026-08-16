{
  pkgs,
  lib,
  selfStr,
  ...
}:

let
  # Named ai-rebuild here and on the MacBook, so an agent runs one command
  # whichever machine it is on. --sudo is gone because the sudoers rule below
  # already runs the whole thing as root, and the repo path comes from selfStr
  # rather than being written out, so a moved checkout cannot leave this
  # pointing at a stale tree.
  ai-rebuild = pkgs.writeShellApplication {
    name = "ai-rebuild";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.nixos-rebuild
    ];
    text = ''
      nixos-rebuild switch \
        --file ${lib.escapeShellArg selfStr} --attr hetztop
    '';
  };

  ai-rebuild-pynixd = pkgs.writeShellApplication {
    name = "ai-rebuild-pynixd";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.nixos-rebuild
    ];
    text = ''
      nixos-rebuild switch \
        --option eval-store unix:///nix/var/nix/daemon-socket/socket \
        --option store unix:///run/pynixd/pynixd.sock \
        --file ${lib.escapeShellArg selfStr} --attr hetztop
    '';
  };
in
{
  environment.systemPackages = [
    ai-rebuild
    ai-rebuild-pynixd
  ];

  # This used to install both scripts as setuid-root wrappers *and* grant
  # NOPASSWD sudo on those wrappers. The setuid half was the dangerous one: a
  # setuid binary is runnable by every user on the machine with no
  # authentication at all, so it handed a full root rebuild to anyone with a
  # shell here. The sudo rule alone gives lillecarl exactly the same thing and
  # gives nobody else anything, so the wrappers are gone.
  #
  # Read this as granting full root, not narrow root: the command activates
  # whatever the checkout at ${selfStr} evaluates to, and that is arbitrary
  # Nix. That is the deliberate trade for a machine an agent is meant to
  # rebuild unattended.
  # The stable path and not the store path, matching ./nix-gc.nix and
  # ./btrfs.nix. sudo compares the command as the caller wrote it, so a rule
  # naming a store path is only matched by someone who typed that store path;
  # `sudo ai-rebuild` resolves through PATH to /run/current-system/sw/bin and
  # has to find itself there. Nothing is given away by using it: only
  # activation can change where it points, and that is root already.
  security.sudo.extraRules = [
    {
      users = [ "lillecarl" ];
      commands =
        map
          (command: {
            inherit command;
            options = [ "NOPASSWD" ];
          })
          [
            "/run/current-system/sw/bin/ai-rebuild"
            "/run/current-system/sw/bin/ai-rebuild-pynixd"
          ];
    }
  ];
}
