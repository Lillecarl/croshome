# Builds ~/.codex/AGENTS.md, the global instruction file the Codex CLI reads
# before every session on this machine.
#
# Same job as ./claude-md.nix does for Claude Code and ./opencode.nix for
# opencode, with one structural difference: Codex has no import mechanism.
# Claude Code splices `@` lines and opencode takes an `instructions` list, so
# those two read the shared prose straight out of the checkout and an edit
# applies to their next session with no rebuild. Codex reads one plain
# markdown file, so this module INLINES the shared prose at build time: an
# edit to home/agents/shared reaches Claude Code and opencode immediately,
# and Codex on the next rebuild.
#
# The prompt coverage here is deliberately just the shared rules. Codex's
# mode of operation differs enough from the other harnesses that its
# harness-specific section stays small: the version-control rule, and
# nothing else yet.
{
  config,
  lib,
  selfStr,
  ...
}:
let
  cfg = config.programs.codexInstructions;

  sharedDir = ./agents/shared;

  # Must agree with the `shared` lists in ./claude-md.nix and ./opencode.nix:
  # together, `shared` and `skip` name every file in ./agents/shared.
  shared = [
    "autonomy.md"
    "next-thing.md"
    "tools.md"
    "commits.md"
    "prose.md"
  ];

  # Shared prose this harness deliberately does not take. A file named here is
  # accounted for without being inlined, so the check below still catches a
  # section nobody reads -- silence about a file is the failure it exists to
  # stop, and "not for Codex" has to be said rather than left out.
  #
  # Codex has no compaction tool. Claude Code gets one from wrapty and opencode
  # from ./agents/opencode/plugins/self-compact.ts, both named `compact`; there
  # is no Codex equivalent to point the rule at.
  skip = [
    "compaction.md"
  ];

  onDisk = dir: lib.attrNames (
    lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".md" n) (builtins.readDir dir)
  );

  # Both directions, because each one fails silently on its own: a name in
  # the list with no file drops the section here, and a file with no entry in
  # the list never reaches a session. Neither shows up as an error anywhere,
  # hence the eval-time check.
  check = {
    missing = lib.subtractLists (onDisk sharedDir) (shared ++ skip);
    unlisted = lib.subtractLists (shared ++ skip) (onDisk sharedDir);
  };

  prose =
    assert lib.assertMsg (check.missing == [ ]) (
      "home/codex-md.nix: `shared` or `skip` names ${toString check.missing}, "
      + "which does not exist in home/agents/shared."
    );
    assert lib.assertMsg (check.unlisted == [ ]) (
      "home/codex-md.nix: home/agents/shared holds ${toString check.unlisted}, "
      + "which neither `shared` nor `skip` names, so it is never inlined and "
      + "nobody decided that."
    );
    lib.concatStringsSep "\n" (map (f: builtins.readFile (sharedDir + "/${f}")) shared);

  header = ''
    # Global preferences

    Nix generates this file. Do not edit `~/.codex/AGENTS.md`: it is a
    read-only store symlink, and the next rebuild replaces it.

    Edit the configuration instead, at `${selfStr}`. The sections after
    Version control come from `home/agents/shared/*.md`, inlined here at
    build time. Claude Code and opencode read that directory live; Codex
    sees an edit to it on the next rebuild.

    ${config.programs.agentMachine.text}

    ## Version control

    Repositories in my checkouts use jj (Jujutsu), not git -- a `.jj` folder
    means jj is in charge. Never run a git command that writes (commit,
    merge, rebase, push, stash, branch) in a jj repo; every write goes
    through `jj`. Read-only git commands (log, diff, show, blame) are fine.
  '';
in
{
  options.programs.codexInstructions = {
    enable = lib.mkEnableOption "the generated ~/.codex/AGENTS.md";
  };

  config = lib.mkIf cfg.enable {
    home.file.".codex/AGENTS.md".text = header + "\n" + prose + "\n";
  };
}
