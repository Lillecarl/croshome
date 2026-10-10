let
  lock = builtins.fromJSON (builtins.readFile ../flake.lock);
  # Through the root's input map, not `nodes.flake-compatish`: a second
  # copy in the graph renames ours to `flake-compatish_2`.
  node = lock.nodes.${lock.nodes.${lock.root}.inputs.flake-compatish};
  flake-compatish = import (builtins.fetchTree node.locked);
in
flake-compatish {
  source = ../.;
  # Evaluate the working copy in place instead of copying it to the store.
  overrides.self = ../.;
}
