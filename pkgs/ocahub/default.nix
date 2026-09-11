{
  lib,
  buildPythonApplication,
  setuptools,
  anyio,
  mcp,
  pyzmq,
  pytestCheckHook,
}:

buildPythonApplication {
  pname = "ocahub";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ setuptools ];
  dependencies = [ anyio mcp pyzmq ];

  nativeCheckInputs = [ pytestCheckHook ];

  pythonImportsCheck = [
    "ocahub"
    "ocahub.mcp_server"
  ];

  meta = {
    description = "Cross-agent message hub for OpenCode: a ZeroMQ broker daemon and client CLI";
    mainProgram = "ocac";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
}
