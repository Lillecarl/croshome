{
  lib,
  buildPythonApplication,
  setuptools,
  anyio,
  pyzmq,
  pytestCheckHook,
}:

buildPythonApplication {
  pname = "ocahub";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ setuptools ];
  dependencies = [ anyio pyzmq ];

  nativeCheckInputs = [ pytestCheckHook ];

  pythonImportsCheck = [ "ocahub" ];

  meta = {
    description = "Cross-agent message hub for OpenCode: a ZeroMQ broker daemon and client CLI";
    mainProgram = "ocac";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
}
