# Python packages Nixpkgs doesn't ship.
#
# These are built with pyproject.nix's own build infrastructure rather than
# `buildPythonPackage`. That is not a workaround -- it is the native way to add
# a package to this set. `buildPythonPackage` produces a Nixpkgs-style output
# (propagated dependencies, wrapper scripts) that would then have to be put back
# through `nixpkgsPrebuilt` to strip all of that off again; defining the package
# here skips the round trip entirely.
#
# The contract for a package in this set is small:
#
#   pname / version        identity
#   src                    where the code comes from
#   nativeBuildInputs      which pyproject hook builds it
#   passthru.dependencies  a { name = [ extras ]; } spec, resolved flat
#
# `passthru.dependencies` is the important one and the easiest to forget:
# nothing propagates here, so a dependency that isn't listed simply won't be in
# the venv. Names are PEP-503 normalised and resolve against this same set --
# so `xonsh` and `notify-py` below find the bridged Nixpkgs builds rather than
# pulling in second copies.
#
# An overlay, so entries can refer to each other (and to bridged Nixpkgs
# packages) through `final`.
{ lib }:
final: _prev:
let
  # Every package here follows the same shape, so the boilerplate lives in one
  # place: fetch a pure-Python wheel from PyPI and install it. No build backend
  # runs, so there is no `build-system` to satisfy and nothing to compile.
  #
  # To add one:
  #   1. Find the wheel:  curl -s https://pypi.org/pypi/<name>/json \
  #                         | jq -r '.urls[]|select(.packagetype=="bdist_wheel").url'
  #   2. Hash it:         nix store prefetch-file --hash-type sha256 <url>
  #   3. Copy `requires_dist` from that same JSON into `dependencies`, keeping
  #      only the runtime names -- drop version bounds (the set has whatever
  #      Nixpkgs pinned) and anything guarded by an `extra == ...` marker.
  wheelPackage =
    {
      pname,
      version,
      url,
      hash,
      dependencies ? { },
      meta ? { },
    }:
    final.callPackage (
      {
        stdenv,
        fetchurl,
        pyprojectWheelHook,
      }:
      stdenv.mkDerivation {
        inherit pname version meta;
        src = fetchurl { inherit url hash; };
        nativeBuildInputs = [ pyprojectWheelHook ];
        passthru = { inherit dependencies; };
      }
    ) { };

  # Builds from source -- an sdist tarball or a git checkout, whichever `src`
  # is. The differences from `wheelPackage` are the two that matter:
  #
  #   pyprojectHook        actually runs a build backend, rather than just
  #                        unpacking an already-built wheel
  #   resolveBuildSystem   supplies that backend, resolved flat from this same
  #                        set exactly like runtime dependencies
  #
  # `buildSystem` defaults to setuptools because a project with no
  # `[build-system]` table at all -- a plain setup.py/setup.cfg, which is what
  # most older xontribs still ship -- is defined by PEP 518 to mean exactly
  # that. For a project that *does* declare one, copy it across: e.g.
  # `buildSystem = { hatchling = [ ]; }` or `{ poetry-core = [ ]; }`. Those
  # resolve to the bridged Nixpkgs builds, so they need no packaging here.
  # `patches` is the reason to prefer an sdist over a wheel for a package that
  # needs fixing: it is an ordinary `mkDerivation` argument, applied to a source
  # tree before the build backend ever runs. A wheel is already built, so there
  # is nothing to patch without unpacking and repacking it by hand.
  sourcePackage =
    {
      pname,
      version,
      src,
      buildSystem ? {
        setuptools = [ ];
        wheel = [ ];
      },
      patches ? [ ],
      dependencies ? { },
      meta ? { },
    }:
    final.callPackage (
      {
        stdenv,
        pyprojectHook,
        resolveBuildSystem,
      }:
      stdenv.mkDerivation {
        inherit
          pname
          version
          src
          patches
          meta
          ;
        nativeBuildInputs = [ pyprojectHook ] ++ resolveBuildSystem buildSystem;
        passthru = { inherit dependencies; };
      }
    ) { };
in
{
  # Terminal integration: prompt marks and OSC sequences. The minimal case --
  # one dependency, already in the set.
  xontrib-term-integrations = wheelPackage {
    pname = "xontrib-term-integrations";
    version = "0.2.3";
    url = "https://files.pythonhosted.org/packages/a7/ea/3f8f28482547e4cca118116848c7fa31bf4e58c90000e8f9eba3e370e480/xontrib_term_integrations-0.2.3-py3-none-any.whl";
    hash = "sha256-BeppTTiZCkMFySx+8ohz9Q1iBppKczH0DvEj9GGLYns=";
    dependencies.xonsh = [ ];
    meta = {
      description = "Terminal integrations for xonsh";
      homepage = "https://github.com/anki-code/xontrib-term-integrations";
      license = lib.licenses.mit;
    };
  };

  # Nixpkgs *has* `openai`, and this deliberately shadows it.
  #
  # Not a version disagreement -- this is the same 2.41.1 wheel Nixpkgs builds.
  # The disagreement is about dependencies. Upstream's metadata puts `numpy`
  # behind the `datalib`/`voice-helpers` extras and `sounddevice` behind
  # `voice-helpers`, but the Nixpkgs build lists them unconditionally, and
  # `bridge.nix` faithfully carries whatever Nixpkgs declares. The result is
  # that asking for an HTTP client to talk to DeepSeek pulls in numpy and a
  # PortAudio binding:
  #
  #   python3 + openai (via Nixpkgs)   525 MB   <- 478 MB of it sounddevice/numpy
  #   python3 + openai (this entry)     55 MB
  #
  # The eight names below are upstream's entire unconditional requirement set,
  # copied from its PyPI `requires_dist`. Nothing needed for chat completions is
  # missing; what is gone is audio and dataframe support this shell will never
  # ask for.
  openai = wheelPackage {
    pname = "openai";
    version = "2.41.1";
    url = "https://files.pythonhosted.org/packages/20/74/925d7b3892927e9804aaf58d374a45dc28e4420ff90e992272b77286343e/openai-2.41.1-py3-none-any.whl";
    hash = "sha256-qTlWXzUMt0Q8uEO4AbiMcWrIAktJL7lMomnV9rG779Y=";
    dependencies = {
      anyio = [ ];
      distro = [ ];
      httpx = [ ];
      jiter = [ ];
      pydantic = [ ];
      sniffio = [ ];
      tqdm = [ ];
      typing-extensions = [ ];
    };
    meta = {
      description = "The official Python library for the OpenAI API";
      homepage = "https://github.com/openai/openai-python";
      license = lib.licenses.asl20;
    };
  };

  # The file tools behind xontrib-pai. Nixpkgs has `pydantic-ai-slim` but not
  # this, which sits on top of it.
  #
  # Both dependencies below are the package's *entire* core requirement set --
  # everything else it can do (Monty sandboxing, Exa, Temporal, DBOS, Modal) is
  # behind a PyPI extra and none of those are requested, so naming these two is
  # the whole packaging job. Both resolve to bridged Nixpkgs builds.
  #
  # Pinned deliberately rather than tracked: the project is pre-1.0 and its own
  # version policy says minor bumps (0.11 -> 0.12) may break the API. This is in
  # the shell someone uses every day, so the upgrade is a decision, not a
  # side effect of a flake update.
  pydantic-ai-harness = wheelPackage {
    pname = "pydantic-ai-harness";
    version = "0.11.0";
    url = "https://files.pythonhosted.org/packages/12/8a/6bafcc983a227f01cdce28becc36ab6fe4baec365ae10bdbec70a986c5b8/pydantic_ai_harness-0.11.0-py3-none-any.whl";
    hash = "sha256-yElyXUZ6mPsB4DWlJre3xIiVKTXj9cm3T1F6PsEfxHo=";
    dependencies = {
      pydantic-ai-slim = [ ];
      httpx = [ ];
    };
    meta = {
      description = "Capability library for Pydantic AI agents";
      homepage = "https://pydantic.dev/docs/ai/harness/";
      license = lib.licenses.mit;
    };
  };

  # Desktop notification after a long-running command. Worth having as an
  # example because its `notify-py` dependency is *not* defined in this file --
  # naming it here resolves it against the bridged Nixpkgs package set, and the
  # flat resolver pulls it (and its own transitive closure) into the venv.
  xontrib-cmd-durations = wheelPackage {
    pname = "xontrib-cmd-durations";
    version = "0.3.2";
    url = "https://files.pythonhosted.org/packages/a1/44/ef6c92aff7fee0ce7a70145fd7d2ea315c7d0feeb12c0e37bac3fdd6cb22/xontrib_cmd_durations-0.3.2-py3-none-any.whl";
    hash = "sha256-qeGxbD47AP+f1P76FpmUH7M6TpAkHIt2MvTtpUBo1m8=";
    dependencies = {
      xonsh = [ ];
      notify-py = [ ];
    };
    meta = {
      description = "Notify when a long-running command finishes in xonsh";
      homepage = "https://github.com/jnoortheen/xontrib-cmd-durations";
      license = lib.licenses.mit;
    };
  };

  # --- Built from source: an sdist tarball ---------------------------------
  #
  # Neither of the next two ships a `pyproject.toml` at all -- just setup.py and
  # setup.cfg -- so the default `buildSystem` above is doing real work.
  tokenize-output = sourcePackage {
    pname = "tokenize-output";
    version = "0.4.10";
    src = final.pkgs.fetchurl {
      url = "https://files.pythonhosted.org/packages/4b/18/a301ad7a8ad40744179544a377c9e660ad6de18321159986aa4f93a859ad/tokenize-output-0.4.10.tar.gz";
      hash = "sha256-KTCXS15H4/sSvkUmCFuHovzJZ4HJlcMGRcM+qcjU0BE=";
    };
    # Leaving this out is the canonical way to get this wrong, and it fails at
    # *runtime*, not build time: the package builds and installs fine, then
    # `xontrib load output_search` dies with `ModuleNotFoundError: No module
    # named 'demjson3'` (observed). Nothing propagates here -- a dependency that
    # isn't named simply isn't in the venv. `demjson3` is in Nixpkgs, so naming
    # it is the entire fix.
    dependencies.demjson3 = [ ];
    meta = {
      description = "Tokenize command output";
      homepage = "https://github.com/anki-code/tokenize-output";
      license = lib.licenses.mit;
    };
  };

  # Depends on `tokenize-output` directly above -- a source-built package
  # depending on another source-built package. Neither exists in Nixpkgs, and
  # neither needed anything beyond a name in `dependencies`: the flat resolver
  # links both into the venv alongside the bridged Nixpkgs packages.
  xontrib-output-search = sourcePackage {
    pname = "xontrib-output-search";
    version = "0.6.6";
    src = final.pkgs.fetchurl {
      url = "https://files.pythonhosted.org/packages/dd/0c/dee502a20fbd4d18a39131f7549c6f72759748251b6a7b95b6d6e6f69e51/xontrib_output_search-0.6.6.tar.gz";
      hash = "sha256-x3nM/+0oIqOIWOTLUxaCtRKgA11bacwRdlJj2styBjI=";
    };
    dependencies.tokenize-output = [ ];
    meta = {
      description = "Get tokens from the previous command output for the next command in xonsh";
      homepage = "https://github.com/anki-code/xontrib-output-search";
      license = lib.licenses.mit;
    };
  };

  # `z` -- zoxide's frecency-ranked directory jumping, plus a completer.
  #
  # The one package here that is *patched* rather than merely packaged, and the
  # reason is the constraint every entry in this file works under: the venv is a
  # read-only Nix store path. This xontrib caches a generated
  # `zoxide_init_cache.py` and imports it on later starts, and it chooses where
  # to put it from `$XDG_CACHE_HOME` -- falling back to its own install
  # directory when that is unset, which it is on most systems. In the store that
  # first write is `OSError: [Errno 30] Read-only file system` and the xontrib
  # never loads at all.
  #
  # The patch applies the basedir spec's own default (`~/.cache`) instead of
  # treating "unset" as "nowhere to cache", so it is a fix rather than a Nix
  # workaround -- see the patch's own header, and send it upstream.
  #
  # Built from the sdist and not the wheel purely so there is a source tree to
  # apply that patch to. `poetry-core` because the project says so.
  #
  # `zoxide` itself is a Rust binary and not a Python dependency at all: this
  # shells out to it. `default.nix` puts it in `paths`.
  xontrib-zoxide = sourcePackage {
    pname = "xontrib-zoxide";
    version = "1.2.1";
    src = final.pkgs.fetchurl {
      url = "https://files.pythonhosted.org/packages/f3/b1/9f8464437ec7dba33717af7891d4c09001bcd5e56976acaf46eeb0d72f4d/xontrib_zoxide-1.2.1.tar.gz";
      hash = "sha256-cHpfU1jhk+Qbjg51bHnuvOXxrW1dmDgP2Ee+2gszsSw=";
    };
    buildSystem.poetry-core = [ ];
    patches = [ ./patches/xontrib-zoxide-xdg-cache.patch ];
    dependencies.xonsh = [ ];
    meta = {
      description = "zoxide integration for xonsh";
      homepage = "https://github.com/dyuri/xontrib-zoxide";
      license = lib.licenses.mit;
    };
  };

  xontrib-fish-completer = wheelPackage {
    pname = "xontrib-fish-completer";
    version = "0.0.3";
    url = "https://files.pythonhosted.org/packages/a4/a7/ace0d475ccaba0963f8f0b679c6fd0ab92f86f8f24cdbb31609793ee8fc2/xontrib_fish_completer-0.0.3-py3-none-any.whl";
    hash = "sha256-wWdNsp5hJjSs5MTxEMMbZMvlI/0jrEPz9EyW3eprgdE=";
    dependencies.xonsh = [ ];
    meta = {
      description = "Fish-style completions for xonsh shell";
      homepage = "https://github.com/xonsh/xontrib-fish-completer";
      license = lib.licenses.mit;
    };
  };

  # direnv (.envrc) support for xonsh shell
  xontrib-envrc = sourcePackage {
    pname = "xontrib-envrc";
    version = "2.0.0";
    src = final.pkgs.fetchzip {
      url = "https://github.com/arkhan/xontrib-envrc/archive/refs/tags/v2.0.0.tar.gz";
      hash = "sha256-/Eh526FZUqZf2+yKfisOfteNv77LeOpt6Ho8EGCJrP0=";
    };
    dependencies.xonsh = [ ];
    meta = {
      description = "direnv (.envrc) support for the xonsh shell";
      homepage = "https://github.com/arkhan/xontrib-envrc";
      license = lib.licenses.mit;
    };
  };

  # --- Built from source: a git checkout -----------------------------------
  #
  # Identical to the sdist case apart from the fetcher -- `src` is just a
  # derivation producing a source tree, so anything that does that works
  # (fetchFromGitHub, fetchgit, fetchzip, or a local path during development).
  xontrib-fzf-widgets = sourcePackage {
    pname = "xontrib-fzf-widgets";
    version = "0-unstable-8af47d1";
    src = final.pkgs.fetchFromGitHub {
      owner = "laloch";
      repo = "xontrib-fzf-widgets";
      rev = "8af47d1d684a14eb776485ef6f5c30c8e6807f60";
      hash = "sha256-lz0oiQSLCIQbnoQUi+NJwX82SbUvXJ+3dEsSbOb20q4=";
    };
    meta = {
      description = "fzf widgets for xonsh";
      homepage = "https://github.com/laloch/xontrib-fzf-widgets";
      license = lib.licenses.gpl3Only;
    };
  };
}
# --- Packages that write to their own install directory -------------------
#
# Worth knowing before you add one: a package that writes next to its own source
# at import time cannot work unmodified here, because the venv lives in the
# read-only Nix store. It needs a patch redirecting the write to a cache
# directory, not just a packaging entry.
#
# `xontrib-zoxide` above is the worked example -- build it from its sdist rather
# than its wheel so there is a source tree, and pass `patches`.
#
# --- Pattern 2: an sdist or git checkout ---------------------------------
#
# When there is no wheel, or you want to build from a tagged source tree, swap
# the hook for `pyprojectHook` and declare the build backend. `resolveBuildSystem`
# takes the same `{ name = [ extras ]; }` shape and resolves it flat, exactly
# like runtime dependencies:
#
#   my-package = final.callPackage (
#     { stdenv, fetchFromGitHub, pyprojectHook, resolveBuildSystem }:
#     stdenv.mkDerivation {
#       pname = "my-package";
#       version = "0.3.0";
#       src = fetchFromGitHub {
#         owner = "someone"; repo = "my-package"; tag = "v0.3.0";
#         hash = "sha256-...";
#       };
#       nativeBuildInputs = [ pyprojectHook ] ++ resolveBuildSystem { setuptools = [ ]; };
#       passthru.dependencies = { xonsh = [ ]; requests = [ ]; };
#     }
#   ) { };
#
# Note this declares dependencies in Nix rather than reading the project's own
# pyproject.toml. Reading it (`loadPyproject { projectRoot = src; }`) works and
# saves the transcription, but `src` is a derivation, so parsing a file inside it
# is import-from-derivation -- it forces a build during evaluation and is
# rejected outright when IFD is disabled. Fine locally; avoid it in anything
# that has to evaluate on a CI runner with `allow-import-from-derivation = false`.
#
# anyxonsh's *own* package sidesteps this precisely because its metadata is a
# Nix attrset to begin with -- see nix/project.nix.
#
# --- Pattern 3: patching a package that does exist ------------------------
#
# For a Nixpkgs package that merely needs a tweak, don't redefine it here.
# Override the Nixpkgs derivation and pass it through `pythonPackages`, so the
# bridge picks up the patched build -- see default.nix's `xontrib-jedi`, which
# disables one broken test with `overridePythonAttrs`.
