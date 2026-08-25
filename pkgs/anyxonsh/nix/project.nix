# anyxonsh's own project metadata, rendered as a Nix attrset rather than kept
# in a pyproject.toml.
#
# `pyproject-nix.lib.project.loadPyproject` takes a `pyproject` argument whose
# default is `lib.importTOML (projectRoot + "/pyproject.toml")` -- the file read
# is only a convenience. Passing the attrset directly means there is no TOML to
# keep in sync, no `toTOML` serialisation step, and no import-from-derivation.
#
# The shape below is ordinary PEP-621 (plus a PEP-518 build-system table), so
# everything pyproject.nix knows how to do with a real pyproject.toml -- marker
# evaluation, extras, build-system resolution -- still applies.
{
  lib,
  pyproject-nix,
  # Python distributions anyxonsh itself pulls into the venv. These are PEP-508
  # requirement strings resolved against the bridged Nixpkgs package set, so
  # the names are PEP-503 normalised Nixpkgs `pname`s.
  extraDependencies ? [ ],
}:
let
  pyproject = {
    project = {
      name = "anyxonsh";
      version = "0.1.0";
      description = "A complete xonsh shell environment, bundled with Nix";
      requires-python = ">=3.11";

      dependencies = [
        "xonsh"
        # Behind the `pai` xontrib. `pydantic-ai-slim` would arrive anyway as a
        # dependency of the harness, and `openai` as its DeepSeek/OpenRouter
        # transport -- both are named here anyway because `xontrib_pai` imports
        # them directly, and this file's own rule is that nothing propagates.
        "pydantic-ai-harness"
        "pydantic-ai-slim"
        "openai"
        # Behind the `catppuccin` xontrib. Catppuccin's own Python package: it
        # carries the four flavour palettes and registers a pygments style per
        # flavour as a `pygments.styles` entry point, so the colours are
        # upstream's rather than a copy of them that drifts.
        "catppuccin"
      ]
      ++ extraDependencies;

      # Not in the shipped shell: `mkAnyxonsh` resolves the venv as
      # `{ anyxonsh = [ ]; }`, so nothing here is pulled in unless something
      # asks for the extra by name. `passthru.devVenv` does, which is what the
      # development shell (and therefore `direnv exec . pytest`) exposes.
      # `pyte` is a terminal emulator: it turns the escape sequences a shell
      # writes into the grid of characters a user would actually see. The pai
      # prompt tests need it because their subject *is* the layout -- whether
      # the prompt ends up back at the bottom after something writes over it --
      # and that question cannot be answered from the raw byte stream, where a
      # redrawn line and a stranded one look much the same.
      # `pytest-timeout` because a good half of these tests drive a real shell
      # through a pty and wait on threads, futures and child processes. Every
      # one of those can wait for ever, and a suite that hangs tells you less
      # than one that fails: CI sits there until something kills it, and the
      # report says nothing about which test stopped.
      # `pyinstrument` is a statistical profiler, and what it is here for is the
      # Helix keymap: every keystroke at the prompt runs the whole of
      # `Editor.feed`, and a keymap that takes a millisecond to answer a key is
      # a shell that feels broken without ever being wrong. See
      # `tests/test_helix_bench.py`, which is skipped unless asked for.
      optional-dependencies.test = [
        "pytest"
        "pytest-timeout"
        "pyte"
        "pyinstrument"
      ];

      # Drives `mkApplication`: the resulting derivation symlinks exactly the
      # scripts this package installs, so `bin/` ends up holding `anyxonsh` and
      # nothing else -- no interpreter, no activate scripts, no pyvenv.cfg.
      scripts.anyxonsh = "anyxonsh.__main__:main";

      # No `[project.entry-points."xonsh.xontribs"]` for the helix xontrib, on
      # purpose. That table is not how a xontrib is *found* -- `get_xontribs()`
      # already discovers `xontrib/helix.py` by scanning the `xontrib`
      # namespace package, so `xontrib load helix` and `xontrib list` both work
      # without it. What the table does is opt the xontrib into
      # `_autoload_xontribs`, which loads every entry point unconditionally
      # *after* the rc files have run.
      #
      # That is wrong twice over here. Helix takes over the entire keymap, so
      # it must not switch itself on for someone who set
      # `$ANYXONSH_EDITING_MODE=emacs`. And rc.xsh's explicit `xontrib load
      # helix` would then be followed by a second, automatic load of the same
      # xontrib -- which `setup()` now tolerates, but should not have to.
      #
      # This matches every xontrib actually bundled here: jedi, abbrevs,
      # cmd_done, fzf-widgets and the rest all ship a module in `xontrib/` and
      # declare no entry point.
    };

    build-system = {
      requires = [ "setuptools" ];
      build-backend = "setuptools.build_meta";
    };

    # rc.xsh is data, not an importable module, so setuptools would otherwise
    # drop it from the wheel and `files("anyxonsh")/"rc.xsh"` would 404.
    #
    # `namespaces = true` (setuptools' own default for this table, spelled out
    # because dropping it would silently unship the xontrib) is what lets
    # `src/xontrib/` be found without an `__init__.py`. It must not have one:
    # `xontrib` is the namespace package every xontrib distribution drops a
    # module into, and shipping an `__init__.py` would hide everyone else's.
    tool.setuptools = {
      packages.find = {
        where = [ "src" ];
        namespaces = true;
      };
      package-data.anyxonsh = [ "*.xsh" ];
    };
  };
in
pyproject-nix.lib.project.loadPyproject { inherit pyproject; }
