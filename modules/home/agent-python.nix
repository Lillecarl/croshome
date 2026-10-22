# A loaded Python venv for agents' one-off scripts, and a section in the
# agent instructions saying how to call it, what it holds and where the
# library source is. Built by ../../pkgs/python-venv.
{
  config,
  lib,
  pkgs,
  selfStr,
  ...
}:
let
  cfg = config.programs.agentPython;
  python = cfg.python;

  package = pkgs.pythonVenv {
    inherit python;
    packages = cfg.packages;
    executables.python = cfg.executableName;
  };

  sitePackages = "${package}/lib/venv/${python.sitePackages}";

  names = lib.sort lib.lessThan (
    lib.unique (map (p: p.pname or (lib.getName p)) package.modules)
  );

  section = ''
    ## Python for scripts: `${cfg.executableName}`

    A script outside a project runs on `${cfg.executableName}`:
    `#!/usr/bin/env ${cfg.executableName}`, or `${cfg.executableName} script.py`.
    A real venv: `sys.executable` stays inside it, so subprocesses see the
    same packages. Full standard library (Python ${python.version}) plus these
    distributions, dependencies included:

    ${lib.concatStringsSep " " names}

    Their source: `${sitePackages}`. Read a library's API there instead of
    guessing it. No `pip install`, no ad-hoc venv. A missing library goes into
    `programs.agentPython.packages` in `${selfStr}`.
  '';
in
{
  options.programs.agentPython = {
    enable = lib.mkEnableOption "a loaded Python venv for agents' scripts";

    python = lib.mkOption {
      type = lib.types.package;
      default = pkgs.python3;
      defaultText = lib.literalExpression "pkgs.python3";
      description = "The interpreter the venv is built on.";
    };

    packages = lib.mkOption {
      type = lib.types.functionTo (lib.types.listOf lib.types.package);
      default = _: [ ];
      example = lib.literalExpression "ps: [ ps.anyio ps.httpx ]";
      description = ''
        Libraries in the venv, as for `python.withPackages`. Definitions in
        several modules merge: each is called and the lists concatenated.
      '';
    };

    executableName = lib.mkOption {
      type = lib.types.str;
      default = "agent-python";
      description = "Name of the interpreter in `home.packages`.";
    };

    instructions = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Describe the venv in the agent instructions (`programs.agentMachine.extraSections`).";
    };

    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = "The built venv.";
    };
  };

  config = lib.mkMerge [
    { programs.agentPython.package = package; }
    (lib.mkIf cfg.enable {
      home.packages = [ package ];
      programs.agentMachine.extraSections = lib.mkIf cfg.instructions section;
    })
  ];
}
