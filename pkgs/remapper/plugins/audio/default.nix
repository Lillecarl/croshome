{
  lib,
  buildPythonPackage,
  hatchling,
  remapper,
  pytestCheckHook,
  avizo,
  pipewire,
  wireplumber,
}:

buildPythonPackage {
  pname = "remapper-audio";
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
  dependencies = [ remapper ];

  nativeCheckInputs = [ pytestCheckHook ];
  pythonImportsCheck = [ "remapper_audio" ];

  # volumectl, pw-play and wpctl.
  passthru.runtimeTools = [
    avizo
    pipewire
    wireplumber
  ];

  meta = {
    description = "Remapper plugin for PipeWire volume and sounds";
    inherit (remapper.meta) license platforms;
  };
}
