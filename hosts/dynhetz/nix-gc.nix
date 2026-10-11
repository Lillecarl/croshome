{ ... }:
let
  # The system-profile path, for the same reason as in ./btrfs.nix: sudo matches
  # what PATH resolves to without following the symlink, and a store path would
  # stop matching on the next Nix update.
  nix-collect-garbage = "/run/current-system/sw/bin/nix-collect-garbage";
in
{
  # The daemon never collects on its own: pynixd manages GC (see
  # ./pynixd.nix), and a second collector deletes what its liveness
  # mirror still counts as alive. So the weekly timer stays off and no
  # min-free/max-free floor is set -- either would let the daemon start
  # a collection pass beside pynixd's.
  nix.gc = {
    automatic = false;
  };

  nix.settings = {
    # Deduplicate the store: one copy of every identical file. The first
    # run walks the whole store and is IO-heavy on the mirror.
    auto-optimise-store = true;
  };
  # Run as root this collects the system profile too, so it drops every old
  # NixOS generation and with them the ability to roll back to one. That is what
  # `-d` is for and it is the point of allowing it, but it is why the rule states
  # the argument exactly rather than taking a wildcard: `-d` and nothing else.
  security.sudo.extraRules = [
    {
      users = [ "lillecarl" ];
      commands = [
        {
          command = "${nix-collect-garbage} -d";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];
}
