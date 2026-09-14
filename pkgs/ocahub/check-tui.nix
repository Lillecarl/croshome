# The TUI end-to-end check: real opencode TUIs under pymux against the
# mock provider and the hub.
#
# It is a derivation of its own, and not a passthru of the ocahub
# package, because its inputs are a desktop stack -- a compositor, a
# terminal, an opencode -- which no ordinary build of the hub should
# carry. It tests the source tree (the tests import ocahub off
# PYTHONPATH), the same way the pyterm suites test theirs.
{
  lib,
  runCommand,
  python3,
  opencode,
  # pymux from the pyterm tree, not nixpkgs' abandoned namesake -- see
  # the overlay's ocahub for the argument.
  pymux,
  # The seat: a headless compositor, the terminal it paints, and the
  # tools that photograph it. The same set the pyterm picture checks
  # use, for the same reasons: sway and not cage (it offers the
  # clipboard protocol), foot and not xterm (it speaks Wayland and
  # nothing else), grim for the output, imagemagick for nothing yet --
  # the seats' diffs may want it later.
  sway-unwrapped,
  foot,
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
runCommand "ocahub-tui-e2e"
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
    meta = {
      description = "ocahub's TUI end-to-end check: opencode under pymux against a mock provider";
      platforms = lib.platforms.linux;
    };
  }
  ''
    set -o pipefail
    cp -r ${./tests} tests
    chmod -R +w tests
    export HOME="$TMPDIR"
    # --basetemp keeps every tmp of the run under $out, so a red run
    # leaves its picture and its logs where a person reads them.
    mkdir -p "$out/tmp"
    PYTHONPATH=${./src} python3 -m pytest tests/test_tui.py \
      -q -p no:cacheprovider --basetemp="$out/tmp" 2>&1 | tee "$TMPDIR/run.log"
    mkdir -p $out
  ''
