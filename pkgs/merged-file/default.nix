{
  lib,
  buildPythonApplication,
  hatchling,
  pyyaml,
  tomli-w,
  pytestCheckHook,
}:

buildPythonApplication {
  pname = "merged-file";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ hatchling ];
  dependencies = [
    pyyaml
    tomli-w
  ];

  # The suite runs against the installed package, so it tests what the
  # activation will actually import. ./tests is not in the wheel: it is
  # source, not something an activation needs at runtime.
  nativeCheckInputs = [ pytestCheckHook ];

  pythonImportsCheck = [
    "mergedfile"
    "mergedfile.cli"
    "mergedfile.merger"
  ];

  meta = with lib; {
    description = "Deep-merge declarative settings into existing JSON, TOML and YAML config files";
    mainProgram = "merged-file";
  };
}
