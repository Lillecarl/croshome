# The ocahub MCP server for OpenCode: tools to list agents and to
# tell/ask/reply them (see pkgs/ocahub/src/ocahub/mcp_server.py). Imported
# per host, because it is only useful where the ocahub user service runs;
# dynhetz for now. The package itself brings the `ocac` CLI as well.
#
# No environment is set in opencode.json: the server takes OCAHUB_NAME
# (default "opencode") and OCAHUB_SESSION (default: fresh per process) from
# the environment, and there is nothing secret to keep out of the store.
{
  lib,
  pkgs,
  ...
}:
{
  home.packages = [ pkgs.ocahub ];

  home.mergedFile.".config/opencode/opencode.json" = {
    format = "json";
    settings.mcp.ocahub = {
      type = "local";
      command = [ (lib.getExe' pkgs.ocahub "ocahub-mcp") ];
      enabled = true;
    };
  };
}
