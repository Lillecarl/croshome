# Builds ~/.claude/CLAUDE.md, the global instruction file Claude Code reads
# before every session on this machine.
#
# The file is half generated and half live. The header below is generated: a
# short preamble, then the machine section ./agent-machine.nix builds, which
# states what differs per machine. The sections after it are plain markdown in
# ./agents/, pulled in with `@` imports that point straight into the checkout.
# ./agents/shared holds rules shared with the other harnesses (see
# ./opencode.nix and ./codex-md.nix); ./agents/claude holds what only Claude
# Code needs. An edit to one of those files applies to the next session with
# no rebuild. An edit here needs one.
#
# That split is deliberate. Prose changes often and structure does not, so
# the part that changes often stays out of the store. It is the same trade
# ./agents.nix makes for the skills directory, for the same reason.
#
# ~/.claude/settings.json stays hand-managed: see ./wrapty.nix for why.
{
  config,
  lib,
  selfStr,
  ...
}:
let
  cfg = config.programs.claudeInstructions;

  header = ''
    # Global preferences

    Nix generates this file. Do not edit `~/.claude/CLAUDE.md`: it is a
    read-only store symlink, and the next rebuild replaces it.

    Edit the configuration instead, at `${selfStr}`.

    - The machine section below comes from `home/agent-machine.nix`, and the
      preamble around it from `home/claude-md.nix`. A change to either needs a
      rebuild.
    - The sections after the header come from `home/agents/shared/*.md` and
      `home/agents/claude/*.md`. The `@` imports at the end of this file point
      straight into the checkout, so an edit to one of those files reaches the
      next session with no rebuild.

    ${config.programs.agentMachine.text}
  '';

  sharedDir = ./agents/shared;
  claudeDir = ./agents/claude;

  # Order matters only for reading. Claude Code splices each import in where
  # the `@` line sits.
  shared = [
    "autonomy.md"
    "next-thing.md"
    "tools.md"
    "commits.md"
    "prose.md"
  ];

  claudeOnly = [
    "ask-user.md"
    "compaction.md"
  ];

  onDisk = dir: lib.attrNames (
    lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".md" n) (builtins.readDir dir)
  );

  # Both directions, because each one fails silently on its own. A name in the
  # list with no file writes an `@` line that resolves to nothing, and the
  # section just disappears from the instructions. A file with no entry in the
  # list is never imported, so a section written today never reaches a session.
  # Neither shows up as an error anywhere, hence the eval-time check.
  check = dir: listed: {
    missing = lib.subtractLists (onDisk dir) listed;
    unlisted = lib.subtractLists listed (onDisk dir);
  };

  sharedCheck = check sharedDir shared;
  claudeCheck = check claudeDir claudeOnly;

  imports' =
    assert lib.assertMsg (sharedCheck.missing == [ ]) (
      "home/claude-md.nix: `shared` names ${toString sharedCheck.missing}, "
      + "which does not exist in home/agents/shared."
    );
    assert lib.assertMsg (sharedCheck.unlisted == [ ]) (
      "home/claude-md.nix: home/agents/shared holds ${toString sharedCheck.unlisted}, "
      + "which `shared` does not name, so it is never imported."
    );
    assert lib.assertMsg (claudeCheck.missing == [ ]) (
      "home/claude-md.nix: `claudeOnly` names ${toString claudeCheck.missing}, "
      + "which does not exist in home/agents/claude."
    );
    assert lib.assertMsg (claudeCheck.unlisted == [ ]) (
      "home/claude-md.nix: home/agents/claude holds ${toString claudeCheck.unlisted}, "
      + "which `claudeOnly` does not name, so it is never imported."
    );
    (lib.concatMapStringsSep "\n" (f: "@${selfStr}/home/agents/shared/${f}") shared)
    + "\n"
    + (lib.concatMapStringsSep "\n" (f: "@${selfStr}/home/agents/claude/${f}") claudeOnly);
in
{
  options.programs.claudeInstructions = {
    enable = lib.mkEnableOption "the generated ~/.claude/CLAUDE.md";
  };

  config = lib.mkIf cfg.enable {
    home.file.".claude/CLAUDE.md".text = header + "\n" + imports' + "\n";
  };
}
