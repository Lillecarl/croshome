{ ... }:
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

  nix.collectGarbage.sudoUsers = [ "lillecarl" ];
}
