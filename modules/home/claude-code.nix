{ lib, ... }:
{
  /**
    Claude Code config directories, relative to $HOME. Every file this
    configuration writes into one goes into each. `.dclaude` is the work
    profile that `dclaude` selects through CLAUDE_CONFIG_DIR.
  */
  options.programs.claudeCode.configDirs = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [
      ".claude"
      ".dclaude"
    ];
  };
}
