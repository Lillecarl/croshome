# domicile's MCP server, for Claude Code on a host that runs the desktop
# (programs.domicile.enable in its NixOS config). `domicile mcp` serves on
# stdio and drives the running desktop; its first tool call asks, in
# Domicile's own dialog, which windows to let the agent in to.
#
# A user-scope `domicile` entry in each Claude config's .claude.json, as
# ./vivarium.nix writes its server. The command is bare `domicile`, the
# NixOS module's, so a rebuild reaches the next server start.
{
  config,
  lib,
  osConfig ? { },
  ...
}:
let
  claudeDirs = config.programs.claudeCode.configDirs;
  # CLAUDE_CONFIG_DIR unset reads ~/.claude.json; set, <dir>/.claude.json.
  userConfigs = [ ".claude.json" ] ++ map (dir: "${dir}/.claude.json") claudeDirs;
in
lib.mkIf (osConfig.programs.domicile.enable or false) {
  # create = false: Claude Code writes its first-run state into an absent
  # .claude.json, and a file made here would skip that.
  home.mergedFile = lib.genAttrs userConfigs (_: {
    format = "json";
    create = false;
    settings.mcpServers.domicile = {
      type = "stdio";
      command = "domicile";
      args = [ "mcp" ];
      env = { };
    };
  });
}
