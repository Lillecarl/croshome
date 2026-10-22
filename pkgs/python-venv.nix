{
  lib,
  buildEnv,
  makeBinaryWrapper,
  runCommand,
}:
/**
  A Python interpreter that starts as a real venv: `sys.prefix` is the venv,
  `sys.executable` points into it, and subprocesses of `sys.executable` see
  the same packages. No PYTHONPATH, no NIX_PYTHONPATH.

  # Inputs

  `python`
  : The interpreter, e.g. `pkgs.python3`.

  `packages`
  : `ps: [ ps.anyio ... ]`, as for `python.withPackages`.

  `name`
  : Name of the executable in `bin/`. Default `"python"`.
*/
{
  python,
  packages ? _: [ ],
  name ? "python",
}:
let
  modules = python.pkgs.requiredPythonModules (packages python.pkgs);
  site = buildEnv {
    name = "${python.name}-venv-site";
    paths = modules;
    pathsToLink = [ "/${python.sitePackages}" ];
  };
  interpreter = "${python}/bin/${python.executable}";
in
runCommand "${python.name}-venv-${name}"
  {
    nativeBuildInputs = [ makeBinaryWrapper ];
    passthru = { inherit python modules; };
    meta.mainProgram = name;
  }
  ''
    venv=$out/lib/venv
    mkdir -p $venv/bin $venv/lib/${python.libPrefix}
    cat > $venv/pyvenv.cfg <<EOF
    home = ${python}/bin
    include-system-site-packages = false
    version = ${python.version}
    executable = ${interpreter}
    EOF
    ln -s ${interpreter} $venv/bin/python
    ln -s ${site}/${python.sitePackages} $venv/${python.sitePackages}

    # CPython looks for pyvenv.cfg beside argv[0] without resolving symlinks,
    # so a profile link to bin/python would start outside the venv. argv[0]
    # must name the venv's own python.
    makeBinaryWrapper ${interpreter} $out/bin/${lib.escapeShellArg name} \
      --argv0 $venv/bin/python
  ''
