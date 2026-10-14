{
  callPackage,
  fetchFromGitHub,
  inputs,
  nixVersions,
}:
let
  # pydd's own wire, for the huggorm lane the library takes as an argument.
  # Only evaluated, never built: the `cli` writer shells out to `nix`, and
  # the planner runs on this package set's Python.
  pyddSources = import "${inputs.nixidae}/pydd/nix/sources.nix";
  huggormSet = import pyddSources.huggorm { sources = pyddSources; };
  pydd = callPackage "${inputs.nixidae}/pydd/lib" {
    huggorm = huggormSet.lanes.nix_2_35.huggorm;
    nix = nixVersions.nix_2_35;
    writer = "cli";
    plannerProtocol = "recursive";
  };
in
pydd.node.npm {
  project = fetchFromGitHub {
    owner = "musistudio";
    repo = "claude-code-router";
    tag = "v3.1.3";
    hash = "sha256-pY+IB8U85PZaKVT7yGFhsmeVjNeobW9b3cc2zwOszxs=";
  };
  name = "claude-code-router";
  program = "ccr";
  # Root `build` also runs electron-builder for the desktop app; the CLI
  # ships these assets alone.
  scripts = [ "build:assets" ];
  # better-sqlite3 compiles here: its install script falls back to node-gyp
  # when the prebuilt download fails, and the sandbox has no network.
  installScripts = [ "better-sqlite3" ];
}
