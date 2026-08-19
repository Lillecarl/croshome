# Puts wrapty on PATH so its Claude Code plugin manifest
# (home/claude/skills/wrapty/) can reference its binaries by bare command
# name (wrapty-mcp, wrapty-hook-stop, wrapty-hook-posttooluse) rather than a
# store path or the old /Users/lillecarl/Dynamist/wrapty/result/... path from
# when wrapty was its own standalone repo. Those manifest files are plain,
# hand-edited JSON under an out-of-store symlink (see ./agents.nix), not
# generated here -- nothing in this module writes to them.
#
# A rebuild does not reach a session that is already running. wrapty is the
# long-lived process wrapping `claude` (see ../home/fish/functions/claude.fish)
# and it owns the control socket the MCP server and hooks talk to, so a switch
# repoints the profile for the *next* session and leaves live ones on the old
# binary. Restart the session to pick a wrapty change up; /reload-plugins is
# not enough, and neither is anything else short of a restart.
#
# This is worth knowing because the hooks behave the opposite way and the
# difference is invisible: ./agents.nix installs the git-write hook as a bare
# command that hooks.json names, so PATH is re-resolved on every invocation
# and a rebuild takes effect at once. Changing the hook needs no restart;
# changing wrapty does. Confirmed by an MCP call against a stale session
# rejecting an argument the new wrapty had just gained.
#
# ~/.claude/settings.json as a whole is deliberately NOT nix-managed: Claude
# Code itself writes to that file at runtime (plugin toggles, model
# selection, trust state), so a nix-generated copy would either get silently
# reverted on the next activation or fight those writes. The one exception is
# the activation script below, which merges in just the `statusLine` key on
# every switch and leaves every other key exactly as Claude Code left it.
#
# This comment used to say `enabledPlugins` had to be set by hand before the
# plugin would load. It does not: a plugin discovered under ~/.claude/skills
# -- the directory ./agents.nix symlinks -- is enabled by default, under the
# marketplace name `skills-dir`. Checked on hetztop with no `enabledPlugins`
# key present at all: `pluginUsage` in ~/.claude.json listed both
# `wrapty@skills-dir` and `jj-worktrees@skills-dir` with a few hundred uses
# between them, and the MCP server was live in a running session. Such
# plugins are also absent from ~/.claude/plugins/installed_plugins.json,
# which only tracks marketplace installs.
#
# Setting it explicitly is harmless. If you do, name every plugin rather than
# only this one -- naming one is what would turn the others off, should that
# key ever be read as an allowlist rather than an override map:
#
#   "enabledPlugins": {
#     "wrapty@skills-dir": true,
#     "jj-worktrees@skills-dir": true
#   }
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.wrapty;

  # Merges `statusLine` into ~/.claude/settings.json, touching nothing else
  # in the file -- see the module comment for why the rest of it stays
  # hand-managed. Read-modify-write via a .tmp file plus os.replace() rather
  # than editing in place, so a crash mid-write can never leave
  # settings.json truncated.
  patchStatusLine = pkgs.writers.writePython3Bin "wrapty-patch-statusline" { } ''
    import json
    import os
    import sys


    def main() -> None:
        settings_path = os.path.expanduser("~/.claude/settings.json")
        command = sys.argv[1]

        try:
            with open(settings_path) as f:
                settings = json.load(f)
        except FileNotFoundError:
            settings = {}

        status_line = {"type": "command", "command": command}
        if settings.get("statusLine") == status_line:
            return
        settings["statusLine"] = status_line

        tmp_path = settings_path + ".tmp"
        with open(tmp_path, "w") as f:
            json.dump(settings, f, indent=2)
            f.write("\n")
        os.replace(tmp_path, settings_path)


    if __name__ == "__main__":
        main()
  '';
in
{
  options.programs.wrapty = {
    enable = lib.mkEnableOption "wrapty (Claude Code PTY wrapper, MCP server, and context-pressure nudge hooks)";
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ pkgs.wrapty ];

    home.activation.wraptyStatusLine = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run mkdir -p "$HOME/.claude"
      run ${lib.getExe patchStatusLine} "${lib.getExe' pkgs.wrapty "wrapty-statusline"}"
    '';
  };
}
