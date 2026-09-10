# Builds opencode's global config from this checkout, mirroring the split
# ./claude-md.nix makes for Claude Code but adapted to what opencode actually
# supports.
#
# opencode does not splice `@` imports the way Claude Code does, so the shared
# prose cannot ride `@` lines into ~/.config/opencode/AGENTS.md. Two pieces
# cover it instead:
#
# - AGENTS.md is an out-of-store symlink to ./agents/opencode/AGENTS.md, which
#   holds only what opencode needs and nothing else. It is plain markdown in
#   the checkout, so an edit to it reaches the next session with no rebuild --
#   the same trade ./agents.nix makes for the skills directory.
# - The shared prose in ./agents/shared is loaded through opencode's
#   `instructions` field, which takes an explicit list of files. That list is
#   merged into ~/.config/opencode/opencode.json through ./merged-file.nix,
#   which leaves the rest of that hand-managed file alone, for the same reason
#   ./wrapty.nix merges `statusLine` into ~/.claude/settings.json: opencode
#   writes nothing to it, but the paths below are machine-specific (selfStr)
#   and belong in the config rather than in prose.
{
  config,
  lib,
  selfStr,
  ...
}:
let
  sharedDir = ./agents/shared;

  # The same four files ./claude-md.nix imports, in the same order. Two lists
  # must agree with the directory, or one of them silently does nothing -- the
  # same eval-time check ./claude-md.nix makes.
  shared = [
    "autonomy.md"
    "next-thing.md"
    "tools.md"
    "commits.md"
    "prose.md"
  ];

  onDisk = lib.attrNames (
    lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".md" n) (builtins.readDir sharedDir)
  );

  missing = lib.subtractLists onDisk shared;
  unlisted = lib.subtractLists shared onDisk;

  # The explicit list, not a glob: a glob would sort alphabetically and lose the
  # reading order, and an explicit list keeps the check above meaningful.
  instructions = map (f: "${selfStr}/home/agents/shared/${f}") shared;
in
{
  config = {
    home.file.".config/opencode/AGENTS.md".source =
      config.lib.file.mkOutOfStoreSymlink "${selfStr}/home/agents/opencode/AGENTS.md";

    home.mergedFile.".config/opencode/opencode.json" =
      assert lib.assertMsg (missing == [ ]) (
        "home/opencode.nix: `shared` names ${toString missing}, "
        + "which does not exist in home/agents/shared."
      );
      assert lib.assertMsg (unlisted == [ ]) (
        "home/opencode.nix: home/agents/shared holds ${toString unlisted}, "
        + "which `shared` does not name, so it is never loaded."
      );
      {
        format = "json";
        settings.instructions = instructions;

        # Reads outside the project root: the store (plugins, MCP wrappers)
        # and the other checkouts under ~/Code. Everything else still asks.
        settings.permission.external_directory = {
          "/nix/store/**" = "allow";
          "~/Code/**" = "allow";
        };
      };

    # Global plugins directory. opencode auto-loads every .ts/.js file in
    # ~/.config/opencode/plugins/. Out-of-store symlink, so editing a plugin
    # reaches the next session with no rebuild -- the same trade ./agents.nix
    # makes for the skills directory.
    home.file.".config/opencode/plugins".source =
      config.lib.file.mkOutOfStoreSymlink "${selfStr}/home/agents/opencode/plugins";
  };
}
