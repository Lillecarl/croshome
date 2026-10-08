{ ... }:
let
  # The system-profile path, for the same reason as in ./btrfs.nix: sudo matches
  # what PATH resolves to without following the symlink, and a store path would
  # stop matching on the next Nix update.
  nix-collect-garbage = "/run/current-system/sw/bin/nix-collect-garbage";
in
{
  # Collect weekly, keeping a month of generations: unattended, because no
  # reminder fires before /nix fills. Like the manual rule below this drops
  # every old generation with it, rollback included -- intended.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  nix.settings = {
    # Deduplicate the store: one copy of every identical file.
    auto-optimise-store = true;
    # Start collecting at 5G free, stop at 20G: this disk is an order of
    # magnitude smaller than dynhetz's mirror, so the floor is lower.
    min-free = "5G";
    max-free = "20G";
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
