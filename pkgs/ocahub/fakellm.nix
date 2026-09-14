# fakellm: the mock LLM provider the TUI checks run against, and not
# something this repo hand-rolls: it speaks both wires the agents speak
# (OpenAI chat and Anthropic messages, SSE included), tracks
# conversations, and takes its behavior from rules. The check's tests
# write rules; this file only gets the upstream package into the store.
{
  lib,
  python3,
}:

python3.pkgs.buildPythonPackage rec {
  pname = "fakellm";
  version = "0.3.5";
  pyproject = true;

  src = python3.pkgs.fetchPypi {
    inherit pname version;
    hash = "sha256-KoEZ0dj4BFcSzfjxNViLoR2qPHjX0LRzdPIu2FjnvpA=";
  };

  build-system = [ python3.pkgs.hatchling ];

  dependencies = [
    python3.pkgs.fastapi
    python3.pkgs.uvicorn
    python3.pkgs.pyyaml
    python3.pkgs.click
  ];

  # The package ships no tests in the sdist; the TUI checks are its
  # judgment here.
  doCheck = false;

  meta = {
    description = "Mock OpenAI/Anthropic server for testing LLM apps";
    homepage = "https://github.com/1dg618/fakellm";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
