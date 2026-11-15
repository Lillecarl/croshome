# Hey Carl's MCP server for OpenCode. The token is not here: OpenCode
# stores it itself after `opencode mcp auth heycarl`, so nothing secret
# reaches the store.
{
  home.mergedFile.".config/opencode/opencode.json" = {
    format = "json";
    settings.mcp.heycarl = {
      type = "remote";
      url = "https://hey.lillecarl.com/mcp";
      enabled = true;
    };
  };
}
