# Composes a complete xonsh environment: a flat venv, an application derivation
# holding only xonsh's entry point, and a wrapper putting Nix packages on PATH.
#
# The pipeline is
#
#   nixpkgs python3Packages
#     -> bridge.mkPythonSet        (flatten: strip propagation, build dep specs)
#     -> pythonSet.mkVirtualEnv    (one site-packages, no PYTHONPATH stacking)
#     -> util.mkApplication        (drop interpreter/activate/pyvenv.cfg)
#     -> wrapProgram               (PATH, XONSH_* env)
{
  lib,
  pkgs,
  pyproject-nix,
  bridge,
}:
let
  inherit (pyproject-nix) build;
  util = pkgs.callPackage build.util { };
in
{
  /*
    Build an anyxonsh environment.

    All arguments are additive: the defaults already give a working shell, and
    each argument extends it rather than replacing anything.
  */
  mkAnyxonsh =
    {
      # Interpreter to build against. Must be the one `pythonPackages` below is
      # drawn from -- nixpkgsPrebuilt rejects a mismatch rather than producing a
      # subtly broken venv.
      python ? pkgs.python3,
      # Extra Python distributions, selected from Nixpkgs' Python package set.
      # Their transitive closure is pulled in automatically.
      pythonPackages ? _ps: [ ],
      # Xontribs, selected from `pkgs.xonsh.passthru.xontribs`.
      xontribs ? _xs: [ ],
      # Programs to place on the shell's PATH. These are ordinary Nixpkgs
      # derivations, not Python packages.
      paths ? [ ],
      # Extra environment variables set before xonsh starts.
      env ? { },
      # Overlays applied to the pyproject.nix package set, for packages Nixpkgs
      # does not ship or that need patching.
      overlays ? [ ],
      # Packages to pull into the venv by *name*, resolved against the
      # pyproject.nix set. This is how anything defined in `overlays` gets in:
      # such a package has no Nixpkgs derivation for `pythonPackages` to take a
      # name from, so it is named here instead.
      extraPackages ? [ ],
      # Where `passthru.devVenv` installs anyxonsh editable from. Only that one
      # attribute reads it, so the default pointing at *this* checkout is right
      # for the only thing it is for: developing anyxonsh itself.
      projectRoot ? toString ../.,
      name ? "anyxonsh",
    }:
    let
      ps = python.pkgs;
      selectedXontribs = xontribs (pkgs.xonsh.passthru.xontribs or { });
      selectedPackages = pythonPackages ps ++ selectedXontribs;

      # anyxonsh's metadata names only `xonsh`; everything the caller asked for
      # is appended here so it becomes a real dependency edge in the venv spec
      # rather than a package that merely happens to be present.
      project = import ./project.nix {
        inherit lib pyproject-nix;
        extraDependencies = map bridge.nameOf selectedPackages ++ extraPackages;
      };

      environ = pyproject-nix.lib.pep508.mkEnviron python;

      # Keeping the metadata in Nix spares us a *maintained* pyproject.toml, but
      # the build backend still needs a real one in the sandbox -- setuptools and
      # uv both read it off disk. `loadPyproject` hands the original attrset back
      # as `project.pyproject`, so serialise exactly that: one source of truth,
      # and the file the backend sees can never drift from the file pyproject.nix
      # resolved dependencies from.
      pyprojectToml = (pkgs.formats.toml { }).generate "pyproject.toml" project.pyproject;

      # Filtered so that editing README.md or a .nix file doesn't rebuild the
      # wheel; only src/ and the generated manifest are inputs.
      src = pkgs.runCommand "anyxonsh-src" { } ''
        mkdir -p "$out"
        cp -r ${
          lib.fileset.toSource {
            root = ../.;
            # Filtered by extension rather than taking `../src` wholesale: a
            # `__pycache__` left behind by any local interpreter run would
            # otherwise become a build input and ship inside the wheel.
            fileset = lib.fileset.fileFilter (f: f.hasExt "py" || f.hasExt "xsh") ../src;
          }
        }/src "$out/src"
        cp ${pyprojectToml} "$out/pyproject.toml"
      '';

      # anyxonsh has to be a member of the package set, not merely built
      # against it: `mkVirtualEnv`'s resolver looks every name in the spec up in
      # the final set, so defining it in an overlay is what makes
      # `{ anyxonsh = []; }` resolvable at all.
      anyxonshOverlay = _final: _prev: {
        anyxonsh = _final.callPackage (
          {
            stdenv,
            pyprojectHook,
            resolveBuildSystem,
          }:
          stdenv.mkDerivation (
            (build.lib.renderers.mkDerivation { inherit project environ; } {
              inherit pyprojectHook resolveBuildSystem;
            })
            // {
              # `renderers.mkDerivation` only sets `src` when the project
              # was loaded from a `projectRoot`; ours is a pure Nix attrset,
              # so the source tree is assembled here instead.
              inherit src;
            }
          )
        ) { };
      };

      pythonSet = bridge.mkPythonSet {
        inherit python;
        roots = [
          ps.xonsh
          # Build-system packages are not in any runtime closure, but
          # `resolveBuildSystem` still looks them up in this set -- both for
          # anyxonsh's declared `setuptools` requirement and for the
          # setuptools+wheel fallback it applies to packages that declare none.
          ps.setuptools
          ps.wheel
        ]
        ++ selectedPackages;
        overlays = overlays ++ [ anyxonshOverlay ];
      };

      anyxonshPackage = pythonSet.anyxonsh;

      # Only `anyxonsh` is named: `resolveCyclic` walks its
      # `passthru.dependencies` -- which the rendered project put xonsh and
      # every caller-supplied package into -- and flattens the whole closure
      # into this one venv.
      venv = pythonSet.mkVirtualEnv "${name}-venv" { anyxonsh = [ ]; };

      # The development venv: the same set, but with anyxonsh installed
      # *editable* and the `test` extra enabled. Kept separate from `venv` so
      # neither pytest nor a path into somebody's home directory can reach the
      # shell people actually run.
      #
      # Editable rather than a `PYTHONPATH=src` in the shellHook, because
      # PYTHONPATH leaks into every subprocess -- including the anyxonsh under
      # test, which would then import a half-edited checkout instead of its own
      # closure. An editable install is scoped to this venv's site-packages.
      #
      # `toString` rather than a path literal: pyproject.nix rejects an editable
      # root inside the store, and a bare `../.` would be copied there. This is
      # therefore only buildable on the non-flake evaluation path (compat.nix,
      # `nix build -f .`, direnv) -- which is the one development uses.
      editableOverlay = final: _prev: {
        anyxonsh = final.callPackage (
          {
            stdenv,
            pyprojectEditableHook,
            resolveBuildSystem,
          }:
          stdenv.mkDerivation (
            (build.lib.renderers.mkDerivationEditable {
              inherit project environ;
              root = projectRoot;
            } { inherit pyprojectEditableHook resolveBuildSystem; })
            // {
              inherit src;
            }
          )
        ) { };
      };

      # pyproject.nix refuses an editable root inside the store, and under
      # flakes the tree *is* in the store -- so `nix flake check`, which
      # evaluates `devShells`, would fail on a development convenience. Fall
      # back to an ordinary venv there: the `test` extra is what CI needs, and
      # editable only matters when there is a checkout to edit.
      editable = !lib.hasPrefix builtins.storeDir projectRoot;

      devVenv =
        (if editable then pythonSet.overrideScope editableOverlay else pythonSet).mkVirtualEnv
          "${name}-dev-venv"
          { anyxonsh = [ "test" ]; };

      # Strips the venv down to just this package's console scripts: `bin/`
      # ends up containing `anyxonsh` alone, with no interpreter or activate
      # scripts leaking into PATH when this lands in a profile.
      app = util.mkApplication {
        inherit venv;
        package = anyxonshPackage;
      };

      # Keeps CPython from putting `~/.local/lib/pythonX.Y/site-packages` on
      # `sys.path` at interpreter startup, where a stale `pip install --user`
      # could shadow a bundled package.
      #
      # This does *not* make the shell fully hermetic, and deliberately so:
      # xonsh's own `xontribs._patch_in_userdir` appends the user site directory
      # by hand whenever it enumerates xontribs and finds itself installed
      # somewhere non-writeable -- which is every Nix install. That is upstream
      # behaviour meant to let `pip install --user xontrib-foo` work against a
      # read-only xonsh, so it is left alone rather than patched out. The net
      # effect: nothing leaks in before xonsh starts, and user-installed
      # xontribs still resolve.
      #
      # `--set-default`, so an explicit value from the caller's environment wins.
      defaultEnv = {
        PYTHONNOUSERSITE = "1";
        # xonsh's own prose documentation, for the `pai` xontrib to read. Taken
        # from the Nixpkgs xonsh's `src`, so it documents the xonsh actually
        # being run rather than whatever is current upstream.
        #
        # Referencing a subdirectory pulls the whole source into the closure --
        # store paths are atomic, so there is no way to depend on `docs/` alone.
        # Filtering it to the 50 text files first would cost ~700 KB instead,
        # and is a `runCommand` away if the closure ever matters.
        XONTRIB_PAI_XONSH_DOCS = "${pkgs.python3Packages.xonsh.src}/docs";
      }
      // env;

      envFlags = lib.concatStringsSep " " (
        lib.mapAttrsToList (
          k: v: "--set-default ${lib.escapeShellArg k} ${lib.escapeShellArg (toString v)}"
        ) defaultEnv
      );
    in
    pkgs.runCommand name
      {
        nativeBuildInputs = [ pkgs.makeWrapper ];
        passthru = {
          inherit
            venv
            devVenv
            pythonSet
            project
            app
            ;
          package = anyxonshPackage;
          # `nix run` and `programs.xonsh` style consumers both look here.
          shellPath = "/bin/anyxonsh";
        };
        meta = {
          description = "A complete xonsh shell environment, bundled with Nix";
          mainProgram = "anyxonsh";
          platforms = lib.platforms.unix;
        };
      }
      ''
        mkdir -p "$out/bin"
        makeWrapper ${app}/bin/anyxonsh "$out/bin/anyxonsh" \
          ${lib.optionalString (paths != [ ]) "--prefix PATH : ${lib.makeBinPath paths}"} \
          ${envFlags}
      '';
}
