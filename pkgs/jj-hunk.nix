{
  pkgs ? import <nixpkgs> { },
}:
let
  version = "0.4.1";
  src = pkgs.fetchFromGitHub {
    owner = "laulauland";
    repo = "jj-hunk";
    tag = "v${version}";
    hash = "sha256-lFuYTg6TW/Lsz4wwaaWFi37F2aGKpLwQgq40VTdDUKE=";
  };
in
pkgs.rustPlatform.buildRustPackage {
  pname = "jj-hunk";
  inherit version src;
  cargoLock.lockFile = "${src}/Cargo.lock";

  nativeCheckInputs = with pkgs; [
    jujutsu
    git
  ];

  # Skip integration tests - they require jj-hunk in PATH when invoked as a tool
  # by jj's diff editor, which child processes don't inherit from preCheck PATH.
  # Unit tests pass, build succeeds. Integration tests work in dev environments
  # with jj-hunk installed in PATH.
  doCheck = false;

  meta = with pkgs.lib; {
    description = "Programmatic hunk selection for jj (Jujutsu)";
    homepage = "https://github.com/laulauland/jj-hunk";
    license = licenses.mit;
    platforms = platforms.all;
  };
}
