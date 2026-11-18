{
  lib,
  buildPythonApplication,
  hatchling,
  anyio,
  evdev,
  pydantic,
  pyudev,
  pytestCheckHook,
  avizo,
  ddcutil,
  libvirt,
  pipewire,
  wireplumber,
}:

buildPythonApplication {
  pname = "remapper";
  version = "0.2.0";
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

  # volumectl (avizo), ddcutil, virsh, wpctl and pw-play.
  makeWrapperArgs = [
    "--prefix"
    "PATH"
    ":"
    (lib.makeBinPath [
      avizo
      ddcutil
      libvirt
      pipewire
      wireplumber
    ])
  ];

  nativeCheckInputs = [ pytestCheckHook ];
  pythonImportsCheck = [ "remapper.daemon" ];

  meta = {
    description = "Numpad remote control for the host, a libvirt VM and DDC/CI monitors";
    license = lib.licenses.mit;
    mainProgram = "remapper";
    platforms = lib.platforms.linux;
  };
}
