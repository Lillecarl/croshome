{
  lib,
  buildPythonApplication,
  hatchling,
  mcp,
  json-rpc,
  jinja2,
  pytestCheckHook,
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

  # The suite runs against the installed package, so it tests what the
  # wrapper will actually import. ./tests is not in the wheel: it is source,
  # not something a session needs at runtime.
  nativeCheckInputs = [ pytestCheckHook ];

  # One entry per console script module. The tests cover the wrapper and the
  # statusline; the MCP server, the hooks and the monitor have none yet, so
  # this is what catches a broken import there -- at build time, rather than
  # in the next session that runs one.
  pythonImportsCheck = [
    "wrapty"
    "wrapty.client"
    "wrapty.hooks"
    "wrapty.mcp"
    "wrapty.monitor"
    "wrapty.statusline"
    "wrapty.wrapper"
  ];

  meta = with lib; {
    description = "Async PTY wrapper with a JSON-RPC control socket and Claude Code MCP/hook integration";
    mainProgram = "wrapty";
  };
}
