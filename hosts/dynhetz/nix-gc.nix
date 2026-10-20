{ ... }:
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
  nix.collectGarbage.sudoUsers = [ "lillecarl" ];
}
