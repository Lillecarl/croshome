# pyedit as an MCP server, for OpenCode and Claude Code. No secrets: the
# server only stages edits the caller could already make through the CLI.
#
# OpenCode takes it through ./merged-file.nix into opencode.json, the same
# shape as ./ocahub-mcp.nix. Claude Code takes it through the skill plugin:
# a directory under ~/.claude/skills carrying .claude-plugin/plugin.json
# naming ./.mcp.json is enabled by default (see ./wrapty.nix), so this
# module links the store SKILL.md together with both generated manifests.
# .gemini keeps the plain skill link in ./agents.nix; only Claude reads the
# plugin wrapper.
#
# The manifests name bare `pyedit`, not a store path, for the reason
# ./wrapty.nix gives: PATH re-resolves on every invocation, so a rebuild
# reaches running sessions at once.
{
  lib,
  pkgs,
  ...
}:
let
  mcpJson = pkgs.writeText "pyedit-mcp.json" (
    builtins.toJSON {
      mcpServers.pyedit = {
        type = "stdio";
        command = "pyedit";
        args = [ "mcp" ];
        env = { };
      };
    }
  );

  pluginJson = pkgs.writeText "pyedit-plugin.json" (
    builtins.toJSON {
      name = "pyedit";
      version = pkgs.pyedit.version;
      description = "Scripted multi-file edits with dry-run diffs.";
      mcpServers = "./.mcp.json";
    }
  );

  # The store skill plus the two manifests, linked rather than copied, so
  # agents always read what the installed CLI teaches.
  claudePlugin = pkgs.runCommand "pyedit-claude-plugin" { } ''
    mkdir -p $out/.claude-plugin
    ln -s ${pkgs.pyedit}/share/skills/pyedit/pyedit/SKILL.md $out/SKILL.md
    ln -s ${mcpJson} $out/.mcp.json
    ln -s ${pluginJson} $out/.claude-plugin/plugin.json
  '';
in
{
  home.file.".claude/skills/pyedit".source = claudePlugin;

  home.mergedFile.".config/opencode/opencode.json" = {
    format = "json";
    settings.mcp.pyedit = {
      type = "local";
      command = [
        (lib.getExe pkgs.pyedit)
        "mcp"
      ];
      enabled = true;
    };
  };
}
