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

  meta = with lib; {
    description = "Async PTY wrapper with a JSON-RPC control socket and Claude Code MCP/hook integration";
    mainProgram = "wrapty";
  };
}
