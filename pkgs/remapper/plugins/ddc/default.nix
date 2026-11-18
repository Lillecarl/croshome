{
  lib,
  buildPythonPackage,
  hatchling,
  remapper,
  anyio,
  pytestCheckHook,
  ddcutil,
}:

buildPythonPackage {
  pname = "remapper-ddc";
  inherit (remapper) version;
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
    remapper
    anyio
  ];

  nativeCheckInputs = [ pytestCheckHook ];
  pythonImportsCheck = [ "remapper_ddc" ];

  passthru.runtimeTools = [ ddcutil ];

  meta = {
    description = "Remapper plugin for DDC/CI monitors through ddcutil";
    inherit (remapper.meta) license platforms;
  };
}
