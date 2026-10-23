# Dev profiles: a service runs its package from a mutable Nix profile, so an
# agent developing it can build and restart it with `devprofile deploy NAME`,
# without a system rebuild.
#
# The service gets `shim` as its package: the pinned package's file tree as
# symlinks into the profile. Every use of the package in the service's module
# (ExecStart, home.packages, wrappers) then follows the profile. Attributes
# read at evaluation (passthru, meta) come from the pinned package.
#
# Activation installs the pinned package into a profile that does not exist
# yet, and leaves an existing one alone; `mode = "pinned"` resets it on every
# activation instead. Profiles under ~/.local/state/nix/profiles are GC roots
# (nix-env registers them in /nix/var/nix/gcroots/auto).
{
  config,
  lib,
  pkgs,
  selfStr,
  ...
}:
let
  cfg = config.programs.devProfiles;
  profileDir = "${config.xdg.stateHome}/nix/profiles/dev";

  profileType = lib.types.submodule (
    { name, config, ... }:
    {
      options = {
        package = lib.mkOption {
          type = lib.types.package;
          description = "The pinned build: installed into a new profile, and what `devprofile reset` returns to.";
        };
        file = lib.mkOption {
          type = lib.types.str;
          default = selfStr;
          description = "What `devprofile deploy` passes to `nix build --file`. Impure, so overrides apply.";
        };
        attr = lib.mkOption {
          type = lib.types.str;
          default = "pkgs.${name}";
          description = "What `devprofile deploy` builds from `file`.";
        };
        units = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "aid.service" ];
          description = "User units `devprofile` restarts after a switch; a stopped one stays stopped.";
        };
        mode = lib.mkOption {
          type = lib.types.enum [
            "dev"
            "pinned"
          ];
          default = "dev";
          description = ''
            `dev`: activation installs `package` only into a missing profile.
            `pinned`: activation resets the profile to `package` every time.
          '';
        };
        profile = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          default = "${profileDir}/${name}";
          description = "The profile's path.";
        };
        shim = lib.mkOption {
          type = lib.types.package;
          readOnly = true;
          description = "Give this to the service as its package.";
        };
      };
      config.shim =
        pkgs.runCommand "${config.package.name}-devprofile"
          {
            passthru = config.package.passthru or { };
            meta = config.package.meta or { };
          }
          ''
            cd ${config.package}
            find . \( -type f -o -type l \) -printf '%P\n' | while IFS= read -r rel; do
              mkdir -p "$out/$(dirname "$rel")"
              ln -s ${lib.escapeShellArg config.profile}/"$rel" "$out/$rel"
            done
          '';
    }
  );

  configJson = pkgs.writeText "devprofile.json" (
    builtins.toJSON (
      lib.mapAttrs (_: p: {
        inherit (p)
          profile
          file
          attr
          units
          mode
          ;
        pinned = "${p.package}";
      }) cfg.profiles
    )
  );

  devprofile =
    pkgs.runCommand "devprofile"
      {
        meta.mainProgram = "devprofile";
      }
      ''
        mkdir -p $out/bin
        { echo '#!${pkgs.python3.withPackages (ps: [ ps.anyio ])}/bin/python3'
          cat ${
            pkgs.replaceVars ./devprofile.py {
              config = configJson;
              nix = lib.getExe pkgs.nix;
              nixEnv = lib.getExe' pkgs.nix "nix-env";
              systemctl = lib.getExe' pkgs.systemd "systemctl";
              journalctl = lib.getExe' pkgs.systemd "journalctl";
            }
          }
        } > $out/bin/devprofile
        chmod 0555 $out/bin/devprofile
      '';

  nixEnv = lib.getExe' pkgs.nix "nix-env";

  activate = lib.concatStrings (
    lib.mapAttrsToList (
      name: p:
      let
        path = lib.escapeShellArg p.profile;
      in
      ''
        if ${
          if p.mode == "pinned" then ''[ "$(readlink -f ${path})" != ${p.package} ]'' else "[ ! -e ${path} ]"
        }; then
          run mkdir -p ${lib.escapeShellArg profileDir}
          run ${nixEnv} --profile ${path} --set ${p.package}
        fi
      ''
    ) cfg.profiles
  );

  section = ''
    ## Dev profiles: `devprofile`

    These services run from a mutable profile, not from the system build:
    ${lib.concatStringsSep ", " (map (n: "`${n}`") (lib.attrNames cfg.profiles))}.
    To run a change to one, `devprofile deploy NAME`: builds `--file <file>
    <attr>` impurely (so `${selfStr}/overrides.nix` checkouts apply),
    switches the profile, try-restarts its units. No ai-rebuild needed. `devprofile list`
    shows what each runs and whether that is the pinned build; `rollback NAME`
    goes back one generation; `reset NAME` returns to the pinned build.
    JSON on stdout, build log on stderr, exit 1 if a step or a unit fails.
  '';
in
{
  options.programs.devProfiles = {
    profiles = lib.mkOption {
      type = lib.types.attrsOf profileType;
      default = { };
      description = "Services that run from a dev profile, by name.";
    };
  };

  config = lib.mkIf (cfg.profiles != { }) {
    home.packages = [ devprofile ];
    home.activation.devProfiles = lib.hm.dag.entryAfter [ "writeBoundary" ] activate;
    programs.agentMachine.extraSections = section;
  };
}
