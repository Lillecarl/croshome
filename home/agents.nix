{
  config,
  pkgs,
  inputs,
  system,
  selfStr,
  ...
}:
{
  # Out-of-store symlinks, so editing a skill takes effect immediately rather
  # than after a rebuild. Both agents read the same directory: a skill is
  # prose, and nothing in it is Claude-specific.
  home.file.".claude/skills".source =
    config.lib.file.mkOutOfStoreSymlink "${selfStr}/home/claude/skills";
  home.file.".gemini/skills".source =
    config.lib.file.mkOutOfStoreSymlink "${selfStr}/home/claude/skills";

  home.packages = [
    # The overlay in ../pkgs tracks upstream releases rather than the nixpkgs
    # pin, and picks the build for the host platform, so this one attribute
    # works on macOS and Linux alike.
    pkgs.claude-code
    pkgs.codex # OpenAI
    pkgs.fabric-ai

    # MCP servers
    pkgs.context7-mcp
    pkgs.mcp-gateway
    pkgs.mcp-nixos
    pkgs.playwright-mcp

    # These three build for macOS as well as Linux, so they are shared. The
    # other two agent CLIs do not, and stay in ./linux -- each was built for
    # aarch64-darwin to find out, because meta.platforms says only that a
    # package is allowed on a platform, not that it works there.
    inputs.acpcli.packages.${system}.acpcli
    inputs.llm-agents.packages.${system}.antigravity-cli
    inputs.llm-agents.packages.${system}.reasonix
  ];
}
