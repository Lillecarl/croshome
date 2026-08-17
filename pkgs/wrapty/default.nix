{
  lib,
  buildPythonApplication,
  hatchling,
  mcp,
  json-rpc,
  jinja2,
}:

buildPythonApplication {
  pname = "wrapty";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ hatchling ];
  dependencies = [
    mcp
    json-rpc
    jinja2
  ];

  meta = with lib; {
    description = "Async PTY wrapper with a JSON-RPC control socket and Claude Code MCP/hook integration";
    mainProgram = "wrapty";
  };
}
