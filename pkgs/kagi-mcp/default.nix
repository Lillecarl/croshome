{
  buildPythonApplication,
  hatchling,
  makeWrapper,
  playwright,
  playwright-stealth,
  fastmcp,
}:
buildPythonApplication {
  pname = "kagi-mcp";
  version = "0.0.1";
  src = ./.;
  pyproject = true;
  build-system = [ hatchling ];
  dependencies = [
    fastmcp
    playwright
    playwright-stealth
    playwright.driver.browsers
  ];
  nativeBuildInputs = [ makeWrapper ];
  postFixup = ''
    wrapProgram $out/bin/kagi-mcp \
      --set-default PLAYWRIGHT_BROWSERS_PATH "${playwright.driver.browsers}" \
      --set-default PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS true
  '';
  passthru.browsers = playwright.driver.browsers;
}
