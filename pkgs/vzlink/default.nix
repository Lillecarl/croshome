{
  lib,
  buildPythonApplication,
  hatchling,
  anyio,
  pytestCheckHook,
}:

buildPythonApplication {
  pname = "vzlink";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ hatchling ];
  dependencies = [ anyio ];

  # The suite runs against the installed package, so it tests what the
  # module will actually exec. ./tests is not in the wheel: it is source,
  # not something the builder needs at runtime.
  nativeCheckInputs = [ pytestCheckHook ];

  # The fakes listen on loopback TCP, which the darwin sandbox denies
  # (EPERM on bind) without this.
  __darwinAllowLocalNetworking = true;

  # One entry per module. The tests cover the rest by running it, so this
  # is what catches a broken import in a module no test executes directly.
  pythonImportsCheck = [
    "vzlink"
    "vzlink.forward"
    "vzlink.guest"
    "vzlink.protocol"
    "vzlink.proxy"
    "vzlink.supervisor"
  ];

  meta = with lib; {
    description = "Host-to-guest link for the Virtualization.framework builder (proxy, supervisor, guest agent)";
    mainProgram = "vzlink-proxy";
  };
}
