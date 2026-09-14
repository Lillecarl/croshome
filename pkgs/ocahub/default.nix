{
  lib,
  buildPythonApplication,
  setuptools,
  anyio,
  mcp,
  pyzmq,
  pytestCheckHook,
  runCommand,
  python3,
  opencode,
  # The TUI check's chain: pymux from the pyterm tree, the terminal the
  # seat paints, and the tools of the headless compositor.
  pymux,
  foot,
  sway-unwrapped,
  grim,
  imagemagick,
  wl-clipboard,
  git,
  makeFontsConf,
  dejavu_fonts,
  runtimeShell,
}:

let
  # A terminal draws with the fonts fontconfig finds, and a build
  # sandbox has no /etc/fonts at all. Without this foot dies at
  # startup, or draws with whatever it falls back to, which is not the
  # same twice. The same reason pymux's own picture checks name it.
  fontsConf = makeFontsConf { fontDirectories = [ dejavu_fonts ]; };
in
buildPythonApplication {
  pname = "ocahub";
  version = "0.1.0";
  pyproject = true;

  src = ./.;

  build-system = [ setuptools ];
  dependencies = [ anyio mcp pyzmq ];

  nativeCheckInputs = [ pytestCheckHook ];

  # The TUI check runs as its own derivation below: it drags in a
  # compositor, a terminal and an opencode, which the ordinary check
  # has no business pulling.
  pytestArgs = [ "-k" "not tui" ];

  pythonImportsCheck = [
    "ocahub"
    "ocahub.mcp_server"
  ];

  passthru.checks.tui-e2e = runCommand "ocahub-tui-e2e"
    {
      nativeBuildInputs = [
        (python3.withPackages (
          ps: [
            ps.pytest
            ps.anyio
            ps.mcp
            ps.pyzmq
          ]
        ))
        pymux
        opencode
        foot
        sway-unwrapped
        grim
        imagemagick
        wl-clipboard
        git
      ];
      env = {
        FONTCONFIG_FILE = fontsConf;
        SHELL = runtimeShell;
        LANG = "C.UTF-8";
        PYTHONDONTWRITEBYTECODE = "1";
      };
    }
    ''
      set -o pipefail
      cp -r ${./tests} tests
      chmod -R +w tests
      export HOME="$TMPDIR"
      # --basetemp keeps every tmp of the run under $out, so a red run
      # leaves its picture and its logs where a person reads them.
      PYTHONPATH=${./src} python3 -m pytest tests/test_tui.py -q \
        -p no:cacheprovider --basetemp="$out/tmp" 2>&1 | tee "$TMPDIR/run.log"
      mkdir -p $out
    '';

  meta = {
    description = "Cross-agent message hub for OpenCode: a ZeroMQ broker daemon and client CLI";
    mainProgram = "ocac";
    license = lib.licenses.asl20;
    platforms = lib.platforms.all;
  };
}
