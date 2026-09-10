# Declarative merges into hand-managed config files.
#
# Some applications own their config file: they read it, write defaults into
# it on first run, or expect a human to edit it. Generating the whole file
# from Nix (home.file / xdg.configFile) fights that ownership -- the app and
# Nix each believe they write it. This module is the middle ground the repo
# already used twice by hand (opencode's `instructions` in ./opencode.nix and
# `mcp.kagi` in ./kagi-mcp.nix): at activation, the merged-file package
# deep-merges `settings` into the file on disk. Mappings recurse, everything
# else (including lists) is replaced, and keys Nix never names are left
# alone. The file stays hand-editable; the merged keys stay declarative and
# checked into git.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.home.mergedFile;
in
{
  options.home.mergedFile = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          options = {
            format = lib.mkOption {
              type = lib.types.enum [
                "json"
                "toml"
                "yaml"
              ];
              example = "json";
              description = ''
                Format of the file at {option}`home.mergedFile.<name>`.
              '';
            };

            settings = lib.mkOption {
              type = (pkgs.formats.json { }).type;
              default = { };
              example = {
                instructions = [
                  "/home/lillecarl/Code/croshome/home/agents/shared/autonomy.md"
                ];
              };
              description = ''
                Values deep-merged into the file at activation, winning over
                whatever is on disk. Mappings recurse; lists and scalars from
                here replace what is on disk. Values must be representable in
                `format`: TOML has no null, so a null here fails loudly at
                activation rather than writing something surprising.
              '';
            };

            create = lib.mkOption {
              type = lib.types.bool;
              default = true;
              example = false;
              description = ''
                Create the file when it does not exist. Disable for
                applications that only write their baseline configuration on
                first run when the file is absent: creating it for them would
                suppress that baseline.
              '';
            };
          };
        }
      )
    );
    default = { };
    example = {
      ".config/opencode/opencode.json" = {
        format = "json";
        settings.instructions = [
          "/home/lillecarl/Code/croshome/home/agents/shared/autonomy.md"
        ];
      };
    };
    description = ''
      Config files to merge declarative settings into at activation, named by
      path relative to $HOME. Several modules may name the same file; their
      `settings` merge as usual. A corrupt file fails the merge loudly rather
      than resetting it, and a file already matching is left untouched.
    '';
  };

  config = lib.mkIf (cfg != { }) {
    home.activation.mergedFiles = lib.hm.dag.entryAfter [ "writeBoundary" ] (
      lib.concatStringsSep "\n" (
        lib.mapAttrsToList (
          relPath: entry:
          let
            settingsFile = pkgs.writeText "merged-file-settings.json" (
              builtins.toJSON entry.settings
            );
          in
          "run ${lib.getExe pkgs.merged-file} --path ${
            lib.escapeShellArg "${config.home.homeDirectory}/${relPath}"
          } --format ${entry.format} --settings ${settingsFile}${
            lib.optionalString (!entry.create) " --no-create"
          }"
        ) cfg
      )
    );
  };
}
