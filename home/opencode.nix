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
#   `instructions` field, which takes an explicit list of files. The activation
#   step below merges that list into ~/.config/opencode/opencode.json and
#   touches nothing else there, for the same reason ./wrapty.nix merges
#   `statusLine` into ~/.claude/settings.json: the rest of that file is
#   hand-managed, and opencode writes nothing to it, but the paths below are
#   machine-specific (selfStr) and belong in the config rather than in prose.
{
  config,
  lib,
  pkgs,
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

  # Merges `instructions` into ~/.config/opencode/opencode.json, touching
  # nothing else in the file. Read-modify-write via a .tmp file plus
  # os.replace() rather than editing in place, so a crash mid-write can never
  # leave the file truncated. `permission` and `provider` stay hand-managed;
  # only this machine-specific pointer is written.
  # E231 and E501: the `instructions` list is a compact JSON array of absolute
  # paths, one long line with no spaces after commas. Both are deliberate;
  # every other flake8 check stays on.
  patchInstructions = pkgs.writers.writePython3Bin "opencode-patch-instructions" { flakeIgnore = [ "E231" "E501" ]; } ''
    import json
    import os

    instructions = ${builtins.toJSON instructions}


    def main() -> None:
        path = os.path.expanduser("~/.config/opencode/opencode.json")

        try:
            with open(path) as f:
                cfg = json.load(f)
        except FileNotFoundError:
            cfg = {}

        if cfg.get("instructions") == instructions:
            return
        cfg["instructions"] = instructions

        tmp_path = path + ".tmp"
        with open(tmp_path, "w") as f:
            json.dump(cfg, f, indent=2)
            f.write("\n")
        os.replace(tmp_path, path)


    if __name__ == "__main__":
        main()
  '';
in
{
  config = {
    home.file.".config/opencode/AGENTS.md".source =
      config.lib.file.mkOutOfStoreSymlink "${selfStr}/home/agents/opencode/AGENTS.md";

    home.activation.opencodeInstructions =
      assert lib.assertMsg (missing == [ ]) (
        "home/opencode.nix: `shared` names ${toString missing}, "
        + "which does not exist in home/agents/shared."
      );
      assert lib.assertMsg (unlisted == [ ]) (
        "home/opencode.nix: home/agents/shared holds ${toString unlisted}, "
        + "which `shared` does not name, so it is never loaded."
      );
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run mkdir -p "$HOME/.config/opencode"
        run ${lib.getExe patchInstructions}
      '';
  };
}
