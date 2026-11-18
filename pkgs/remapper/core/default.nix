{
  lib,
  buildPythonPackage,
  hatchling,
  anyio,
  evdev,
  pydantic,
  pyudev,
  pytestCheckHook,
}:

buildPythonPackage {
  pname = "remapper";
  version = "0.3.0";
  pyproject = true;

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./pyproject.toml
      ./src
      ./tests
    ];
  };

  build-system = [ hatchling ];
  dependencies = [
    anyio
    evdev
    pydantic
    pyudev
  ];

  nativeCheckInputs = [ pytestCheckHook ];
  pythonImportsCheck = [ "remapper.daemon" ];

  meta = {
    description = "Numpad remote control, with the actions in plugins";
    license = lib.licenses.mit;
    mainProgram = "remapper";
    platforms = lib.platforms.linux;
  };
}
