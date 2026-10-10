{
  lib,
  stdenv,
  runCommand,
  versionCheckHook,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "greet";
  version = "0.1.0";

  # Only what the build reads. Editing a .nix file or the README then
  # leaves the derivation hash alone.
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../Makefile
      ../src
    ];
  };

  strictDeps = true;
  __structuredAttrs = true;

  makeFlags = [
    "PREFIX=${placeholder "out"}"
    "VERSION=${finalAttrs.version}"
  ];

  doInstallCheck = true;
  nativeInstallCheckInputs = [ versionCheckHook ];

  passthru.tests.greets-by-name =
    runCommand "${finalAttrs.pname}-greets-by-name" { nativeBuildInputs = [ finalAttrs.finalPackage ]; }
      ''
        [ "$(greet nix)" = "Hello, nix!" ]
        touch $out
      '';

  meta = {
    description = "Print a greeting";
    license = lib.licenses.mit;
    mainProgram = "greet";
    platforms = lib.platforms.unix;
  };
})
