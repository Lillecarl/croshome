# Bridges Nixpkgs' Python package set into a pyproject.nix *build* package set,
# which is what makes `mkVirtualEnv` usable here.
#
# Why this file exists at all: pyproject.nix's build infrastructure resolves
# dependencies **flat**. Nixpkgs propagates them -- every `buildPythonPackage`
# carries `propagatedBuildInputs`, and an environment ends up as a stack of
# store paths glued together on `PYTHONPATH`. pyproject.nix instead expects
# each package to declare `passthru.dependencies` (a `{ name = [ extras ]; }`
# spec) and *does not* propagate; `resolveCyclic` walks those specs, returns
# one flat list of package names, and `mkVirtualEnv` symlinks all of them into
# a single `site-packages`. That flattening is the whole reason to use
# mkVirtualEnv over `python.withPackages`.
#
# The normal way to populate such a set is uv2nix, reading a `uv.lock`. We
# don't want a lockfile -- we want Nixpkgs' already-cached builds. So this
# re-publishes Nixpkgs packages through `hacks.nixpkgsPrebuilt`, which strips
# Nixpkgs' dependency propagation and wrapper scripts and hands back a plain
# output tree the venv builder can link.
#
# Caveat inherited from `nixpkgsPrebuilt`: because wrapper scripts are thrown
# away, any package that depends on another program being injected onto `$PATH`
# by its Nixpkgs wrapper will not find it. Put such programs on PATH explicitly
# via `mkAnyxonsh`'s `paths` argument instead.
{
  lib,
  pkgs,
  pyproject-nix,
}:
let
  inherit (pyproject-nix) build;
  hacks = build.hacks { inherit pkgs lib; };

  # PEP-503 normalised name. pyproject.nix keys its package set (and therefore
  # every `dependencies` spec) by this form, while Nixpkgs `pname`s are only
  # loosely normalised -- `ruamel.yaml`, `typing_extensions` and friends would
  # otherwise never match the names a rendered pyproject refers to.
  normalize = name: lib.toLower (lib.replaceStrings [ "_" "." ] [ "-" "-" ] name);

  nameOf = drv: normalize (drv.pname or (lib.getName drv));

  isPythonDrv = d: lib.isDerivation d && d ? pythonModule;

  # `dependencies` is occasionally a nested list (Nixpkgs permits list-valued
  # entries for conditional deps), and always contains non-Python entries for
  # some packages, so flatten first and keep only real Python modules.
  pythonDepsOf = drv: lib.filter isPythonDrv (lib.flatten (drv.dependencies or [ ]));

  # A pyproject.nix dependency spec: { name = [ extras ]; }. Nixpkgs gives us
  # no extras information on an already-built package -- the extras it was
  # built with are baked into its output -- so every edge is extras-free.
  mkSpec = deps: lib.listToAttrs (map (d: lib.nameValuePair (nameOf d) [ ]) deps);

  optionalDepsOf =
    drv:
    lib.mapAttrs (_: deps: mkSpec (lib.filter isPythonDrv (lib.flatten deps))) (
      drv.optional-dependencies or { }
    );

  # Turn one Nixpkgs Python derivation into a pyproject.nix package.
  bridge =
    python: drv:
    (hacks.nixpkgsPrebuilt {
      from = drv;
      prev = {
        passthru = {
          dependencies = mkSpec (pythonDepsOf drv);
          optional-dependencies = optionalDepsOf drv;
          dependency-groups = { };
        };
      };
    }).overrideAttrs
      (old: {
        # `nixpkgsPrebuilt` copies `nix-support` while dropping
        # `propagated-build-inputs` -- and for most Nixpkgs Python packages that
        # is the *only* file there, so the result arrives with no setup-hook at
        # all. pyproject.nix's build phase discovers build-system packages
        # purely through a setup-hook that appends to
        # `NIX_PYPROJECT_PYTHONPATH`, so without this a bridged `setuptools`
        # resolves as a dependency and then fails to import during the build.
        # Appended to `installPhase` rather than `postInstall` because
        # nixpkgsPrebuilt's installPhase never calls `runHook postInstall`.
        installPhase = old.installPhase + ''
          mkdir -p "$out/nix-support"
          # An existing hook cannot be appended to in place: it arrives either
          # as a symlink into another store path (pytest) or as a mode-444 copy
          # (setuptools), and both reject the `>>` below. Read it out, drop it,
          # write it back -- `rm` only needs the *directory* to be writable.
          if [ -e "$out/nix-support/setup-hook" ]; then
            hook=$(cat "$out/nix-support/setup-hook")
            rm -f "$out/nix-support/setup-hook"
            printf '%s\n' "$hook" > "$out/nix-support/setup-hook"
          fi
          echo 'addToSearchPath NIX_PYPROJECT_PYTHONPATH '"$out/${python.sitePackages}" \
            >> "$out/nix-support/setup-hook"
        '';
      });

  # Breadth-first walk of the Nixpkgs dependency graph, accumulating a flat
  # `normalisedName -> nixpkgs derivation` map. Guarding on `acc ? ${key}`
  # both dedupes diamonds and terminates on the dependency cycles Nixpkgs
  # tolerates but a naive recursion would not.
  collect =
    roots:
    let
      go =
        acc: drv:
        let
          key = nameOf drv;
        in
        if acc ? ${key} then
          acc
        else
          lib.foldl' go (acc // { ${key} = drv; }) (
            pythonDepsOf drv ++ lib.concatMap pythonDepsOf (lib.attrValues (drv.optional-dependencies or { }))
          );
    in
    lib.foldl' go { } (lib.filter isPythonDrv (lib.flatten roots));
in
{
  inherit
    normalize
    nameOf
    collect
    bridge
    ;

  /*
    Build a pyproject.nix package set exposing all of Nixpkgs' Python packages,
    ready for `mkVirtualEnv`.

    `python` must be the interpreter the packages were built against -- mixing
    them trips nixpkgsPrebuilt's own ABI check.
  */
  mkPythonSet =
    {
      python,
      # Nixpkgs Python derivations whose closure must be resolvable by
      # normalised *pname*. See `closureOverlay` below for why this matters even
      # though the whole of `python.pkgs` is already exposed.
      roots ? [ ],
      # Extra overlays applied last, for packages that have no Nixpkgs
      # equivalent or that need patching.
      overlays ? [ ],
    }:
    let
      # Every Nixpkgs Python package, keyed by normalised *attribute* name.
      #
      # This is lazy in the values: `mapAttrs'` only forces attribute names, so
      # nothing is bridged (or even evaluated) until some venv spec actually
      # names it. That keeps the whole of `python3Packages` available -- add a
      # package by naming it, no root registration needed -- at no eval cost for
      # the ones nobody asked for.
      #
      # Members that aren't Python packages -- `buildPythonPackage`,
      # `makeSetupHook`, `fetchPypi`, the various build hooks -- pass through
      # untouched. They have to: the scope resolves `callPackage` arguments
      # through `newScope`, so pyproject.nix's own infrastructure (notably
      # `pyprojectHook`) picks its dependencies out of this same set, and
      # bridging a setup hook as though it were a distribution breaks the set
      # from the inside. The test runs inside the value thunk, so it costs an
      # evaluation only for attributes something actually demanded.
      fullOverlay =
        _final: prev:
        removeAttrs
          (lib.mapAttrs' (
            name: v: lib.nameValuePair (normalize name) (if isPythonDrv v then bridge python v else v)
          ) python.pkgs)
          # The pyproject.nix scope's own infrastructure (`python`, `pkgs`,
          # `stdenv`, `mkVirtualEnv`, the hooks, ...) shares names with members
          # of `python.pkgs`. Clobbering those would break the set itself, so
          # anything the base scope already defines stays untouched.
          (lib.attrNames prev);

      # Nixpkgs attribute names and PEP-503 distribution names mostly agree, but
      # not always (`pkgs.python3Packages.pyyaml` builds `PyYAML`). Dependency
      # specs are generated from *pnames*, so re-key the reachable closure by
      # pname on top of the attribute-name-keyed set to close that gap.
      closureOverlay = _final: _prev: lib.mapAttrs (_: drv: bridge python drv) (collect roots);

      baseSet = pkgs.callPackage build.packages { inherit python; };
    in
    lib.foldl' (set: overlay: set.overrideScope overlay) baseSet (
      [
        fullOverlay
        closureOverlay
      ]
      ++ overlays
    );
}
