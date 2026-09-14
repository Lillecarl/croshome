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

  # The TUI tests (marker `tui`) run the real opencode TUI under pymux
  # and need a compositor, a terminal and an opencode on PATH. They are
  # judged by ocahub-tui-e2e, a derivation of its own -- the ordinary
  # check has no business pulling a desktop stack.
  disabledTestMarks = [ "tui" ];

  pythonImportsCheck = [
    "ocahub"
    "ocahub.mcp_server"
  ];

  meta = {
    description = "Cross-agent message hub for OpenCode: a ZeroMQ broker daemon and client CLI";
    mainProgram = "ocac";
    license = lib.licenses.asl20;
    platforms = lib.platforms.all;
  };
}
