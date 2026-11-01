# pymux-mcp for Claude Code, in every project: the skill pymux-mcp ships at
# share/skills/pymux-mcp/pymux-mcp is also a Claude Code plugin (its own
# .claude-plugin/plugin.json and .mcp.json), and a plugin under ~/.claude/skills
# is enabled by default (see ../modules/home/wrapty.nix). Its .mcp.json starts
# bare `pymux-mcp`, so the package goes on the PATH as well.
#
# Claude Code starts the server at session start; only the tool schemas wait
# until a session searches for them. No setting starts a stdio server later.
#
# pymux's own two skills (the CLI, and jobs) are plain skills, for every agent.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  # From the pyterm tree with this configuration's `pkgs`, as ./pymux.nix's
  # module builds pymux, so the two come from one revision.
  pymux-mcp = (import inputs.pyterm.outPath { inherit pkgs; }).pymux-mcp;
  pymuxSkills = "${config.programs.pymux.package}/share/skills/pymux";
  plainSkills =
    agentDir:
    lib.genAttrs' [ "pymux" "pymux-jobs" ] (
      name: lib.nameValuePair "${agentDir}/skills/${name}" { source = "${pymuxSkills}/${name}"; }
    );
  claudeDirs = config.programs.claudeCode.configDirs;
in
{
  # The command alone: the package is a virtualenv, and its bin/activate and
  # bin/python collide with pymux's own in home-manager-path.
  home.packages = [
    (pkgs.runCommand "pymux-mcp-command" { } ''
      mkdir -p $out/bin
      ln -s ${lib.getExe pymux-mcp} $out/bin/pymux-mcp
    '')
  ];

  home.file = lib.mkMerge (
    map (dir: {
      "${dir}/skills/pymux-mcp".source = "${pymux-mcp}/share/skills/pymux-mcp/pymux-mcp";
    }) claudeDirs
    ++ map plainSkills (claudeDirs ++ [ ".gemini" ])
  );
}
