{
  lib,
  buildPythonPackage,
  hatchling,
  remapper,
  anyio,
  evdev,
  pytestCheckHook,
  libvirt,
}:

buildPythonPackage {
  pname = "remapper-libvirt";
  inherit (remapper) version;
  pyproject = true;

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./70-remapper.rules
      ./pyproject.toml
      ./src
      ./tests
    ];
  };

  build-system = [ hatchling ];
  dependencies = [
    remapper
    anyio
    evdev
  ];

  # services.udev.packages picks it up.
  postInstall = ''
    install -Dm444 70-remapper.rules -t $out/lib/udev/rules.d
  '';

  nativeCheckInputs = [ pytestCheckHook ];
  pythonImportsCheck = [ "remapper_libvirt" ];

  # virsh. libvirt here is the top-level package, not the Python bindings.
  passthru.runtimeTools = [ libvirt ];

  meta = {
    description = "Remapper plugin for a libvirt VM, its USB passthrough and its input";
    inherit (remapper.meta) license platforms;
  };
}
