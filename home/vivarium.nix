# vivarium, nixidae's NixOS test runner, for every agent: the CLI on PATH,
# the skill the package ships, and its MCP server.
#
# The MCP server is a user-scope `vivarium` entry in each Claude config's
# .claude.json, not a skills-dir plugin as ./pyedit-mcp.nix is. Claude Code
# matches a plugin's server to others by command, but user, project and local
# servers by name, and project wins over user. So nixidae's own .mcp.json,
# which builds vivarium-mcp from the working tree, replaces this one inside
# nixidae, and only there. The command is bare `vivarium-mcp`, so a rebuild
# reaches the next server start.
#
# Linux only: vivarium runs no guest on darwin.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  claudeDirs = config.programs.claudeCode.configDirs;
  skill = "${pkgs.vivarium}/share/skills/vivarium/vivarium";
  server = {
    type = "stdio";
    command = "vivarium-mcp";
    args = [ ];
    env = { };
  };
  # CLAUDE_CONFIG_DIR unset reads ~/.claude.json; set, <dir>/.claude.json.
  # Every dir in claudeDirs is used both ways (dclaude sets it to ~/.claude).
  userConfigs = [ ".claude.json" ] ++ map (dir: "${dir}/.claude.json") claudeDirs;
in
lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
  home.packages = [ pkgs.vivarium ];

  home.file = lib.genAttrs (map (dir: "${dir}/skills/vivarium") (claudeDirs ++ [ ".gemini" ])) (_: {
    source = skill;
  });

  # create = false: Claude Code writes its first-run state into an absent
  # .claude.json, and a file made here would skip that.
  home.mergedFile = lib.genAttrs userConfigs (_: {
    format = "json";
    create = false;
    settings.mcpServers.vivarium = server;
  });
}
