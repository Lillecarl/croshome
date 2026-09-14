# The TUI end-to-end check: real opencode TUIs under pymux against the
# mock provider and the hub.
#
# It is a derivation of its own, and not a passthru of the ocahub
# package, because its inputs are a desktop stack -- a compositor, a
# terminal, an opencode -- which no ordinary build of the hub should
# carry. It tests the source tree (the tests import ocahub off
# PYTHONPATH), the same way the pyterm suites test theirs.
#
# It is a suite in pyterm's sense, run by that tree's nix/suite.nix:
# two derivations. The **run** never fails; its output holds the log,
# whatever the tests left behind, and a `status` file. The **verdict**
# reads the status and fails, pointing at the run. The attribute this
# file exports is the verdict; `.run` is the evidence, and it survives
# a red run -- nix throws away the output of a build that failed,
# never of one that succeeded. A red run is therefore cached too:
# `--rebuild` makes it go again.
#
# Eval-time knobs, read from the calling shell and put in the
# derivation's env, so a change to one is a new derivation -- the way
# the pyterm checks take theirs:
#
#   OCAHUB_TUI_TESTS  node ids, default the whole TUI suite
#   OCAHUB_TUI_ARGS   extra pytest flags, for instance `-k rename`
#
#   OCAHUB_TUI_ARGS='-k rename' nix build --file . pkgs.ocahub-tui-e2e.run
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
  # The mock provider the agents run against, and the second agent
  # format the suite stands up.
  ocahub-fakellm,
  claude-code,
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
  # The two-derivation suite runner from the pyterm tree: the run
  # keeps its evidence, the verdict keeps the gate.
  suite,
}:

let
  # A terminal draws with the fonts fontconfig finds, and a build
  # sandbox has no /etc/fonts at all. Without this foot dies at
  # startup, or draws with whatever it falls back to, which is not the
  # same twice. The same reason pymux's own picture checks name it.
  fontsConf = makeFontsConf { fontDirectories = [ dejavu_fonts ]; };

  tuiTests =
    let
      value = builtins.getEnv "OCAHUB_TUI_TESTS";
    in
    if value == "" then "tests/test_tui.py" else value;
  tuiArgs = builtins.getEnv "OCAHUB_TUI_ARGS";
in
suite
  {
    name = "ocahub-tui-e2e";
    inputs = [
        (python3.withPackages (
          ps: [
            ps.pytest
            ps.pytest-timeout
            ps.anyio
            ps.mcp
            ps.pyzmq
          ]
        ))
      ocahub
      pymux
      # The mock provider: the agents' models, on both wires.
      ocahub-fakellm
      opencode
      # The second agent format the suite stands up: claude-code,
      # against the mock's Anthropic route.
      claude-code
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
      # The knobs: in `env`, so a change to one rebuilds the check,
      # which is what makes them work.
      inherit tuiTests tuiArgs;
      # TEMP: the pane-process dump, for a TUI that never paints.
      OCAHUB_DEBUG_PROC = builtins.getEnv "OCAHUB_DEBUG_PROC";
    };
    setup = ''
      cp -r ${./tests} tests
      chmod -R +w tests
      # pytest reads its settings from the root it runs in: the markers
      # the suite uses are declared here, and an unregistered mark is a
      # warning today and an error the day strict mode lands.
      cp ${./pyproject.toml} .
      # The hub plugin travels with the check: the rename test stands on
      # it, and the tests deploy it into each agent's config from here.
      export OCAHUB_PLUGIN="${./opencode-plugin/ocahub-stop-hook.ts}"
      export HOME="$TMPDIR"
    '';
  }
  ''
    # The tmp of the run lives in $TMPDIR, and only then is copied to
    # $out: the hub's ipc sockets live inside it, and a unix socket
    # path may not exceed 107 characters -- the store path of $out
    # alone is over half that, and a socket that cannot be bound ends
    # the run before it starts. (Measured: ZMQError, sizeof
    # sockaddr_un.sun_path.)
    # faulthandler_timeout dumps every thread's stack after sixty
    # stuck seconds and keeps going: a wedged run says where it is
    # wedged, in its own log.
    mkdir -p "$TMPDIR/tmp"
    PYTHONPATH=${./src} timeout 900 python3 -m pytest $tuiTests \
      -q -p no:cacheprovider -o faulthandler_timeout=60 $tuiArgs \
      --basetemp="$TMPDIR/tmp"
    code=$?
    # Whatever the verdict, the run's own directory goes out with it:
    # the panes' pictures, the opencode and hub logs. The copy skips
    # sockets and pipes: the hub's runtime dir is full of them, and a
    # store path may hold neither -- nix scans the output and rejects
    # what it finds.
    cp -r "$TMPDIR/tmp" "$out/tmp" 2>/dev/null || true
    find "$out/tmp" \( -type s -o -type p \) -delete 2>/dev/null || true
    # The suite runner reads the exit of this whole body, so the
    # cleanup lines may not be its last word: end with the code the
    # tests returned, not the code of the tidying.
    exit $code
  ''
