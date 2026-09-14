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
  # The built hub: opencode's config names the `ocahub-mcp` entry
  # point, and that binary lives in this package's bin. Nothing
  # circular here -- the check depends on the package, never the
  # reverse.
  ocahub,
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
      ocahub
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
      PYTHONUNBUFFERED = "1";
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
    # pytest reads its settings from the root it runs in: the markers
    # the suite uses are declared here, and an unregistered mark is a
    # warning today and an error the day strict mode lands.
    cp ${./pyproject.toml} .
    export HOME="$TMPDIR"
    # The tmp of the run lives in $TMPDIR, and only then is copied to
    # $out: the hub's ipc sockets live inside it, and a unix socket
    # path may not exceed 107 characters -- the store path of $out
    # alone is over half that, and a socket that cannot be bound ends
    # the run before it starts. (Measured: ZMQError, sizeof
    # sockaddr_un.sun_path.)
    # faulthandler_timeout dumps every thread's stack after sixty
    # stuck seconds and keeps going: a wedged run says where it is
    # wedged, in its own log.
    set -o pipefail
    mkdir -p "$out"
    if PYTHONPATH=${./src} timeout 900 python3 -m pytest tests/test_tui.py \
      -q -p no:cacheprovider -o faulthandler_timeout=60 \
      --basetemp="$TMPDIR/tmp" 2>&1 | tee "$TMPDIR/run.log"; then
      code=0
    else
      code=$?
    fi
    # A red run leaves its picture and its logs where a person reads
    # them. timeout's kill would also land here -- the log still goes
    # out, the verdict does not survive it. The copy skips sockets and
    # pipes: the hub's runtime dir is full of them, and a store path
    # may hold neither -- nix scans the output and rejects what it
    # finds.
    cp -r "$TMPDIR/tmp" "$out/tmp" 2>/dev/null || true
    find "$out/tmp" \( -type s -o -type p \) -delete 2>/dev/null || true
    cp "$TMPDIR/run.log" "$out/run.log" 2>/dev/null || true
    exit $code
  ''
