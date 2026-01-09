# This module defines global configuration for the xonsh shell.
{
  config,
  lib,
  pkgs,
  osConfig ? { },
  ...
}:
let
  cfg = config.programs.xonsh;
  finalPackage = cfg.package.override { inherit (cfg) extraPackages; };
  bashCompletionPath = "${cfg.bashCompletion.package}/share/bash-completion/bash_completion";
in
{
  options = {
    programs.xonsh = {
      enable = lib.mkOption {
        default = false;
        description = ''
          Whether to configure xonsh as an interactive shell.
        '';
        type = lib.types.bool;
      };

      package = lib.mkPackageOption pkgs "xonsh" {
        extraDescription = ''
          The argument `extraPackages` of this package will be overridden by
          the option `programs.xonsh.extraPackages`.
        '';
      };

      config = lib.mkOption {
        default = "";
        description = ''
          Extra text added to the end of `~/.config/xonsh/rc.xsh`,
          the system-wide control file for xonsh.
        '';
        type = lib.types.lines;
      };

      extraPackages = lib.mkOption {
        default = (ps: [ ]);
        defaultText = lib.literalExpression "ps: [ ]";
        example = lib.literalExpression ''
          ps: with ps; [ numpy xonsh.xontribs.xontrib-vox ]
        '';
        type =
          with lib.types;
          coercedTo (listOf lib.types.package) (v: (_: v)) (functionTo (listOf lib.types.package));
        description = ''
          Xontribs and extra Python packages to be available in xonsh.
        '';
      };

      fishCompletion = {
        enable = lib.mkEnableOption "fish completions for xonsh";
      };

      bashCompletion = {
        enable = lib.mkEnableOption "bash completions for xonsh" // {
          default = true;
        };
        package = lib.mkPackageOption pkgs "bash-completion" { };
      };
    };

  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      xdg.configFile."xonsh/rc.xsh".text = ''
        # ${config.xdg.configHome}/xonsh/rc.xsh: DO NOT EDIT -- this file has been generated automatically.

        if not ''${...}.get('__NIXOS_SET_ENVIRONMENT_DONE'):
            # The NixOS environment and thereby also $PATH
            # haven't been fully set up at this point. But
            # `source-bash` below requires `bash` to be on $PATH,
            # so add an entry with bash's location:
            $PATH.add('${pkgs.bash}/bin')

            # Stash xonsh's ls alias, so that we don't get a collision
            # with Bash's ls alias from environment.shellAliases:
            _ls_alias = aliases.pop('ls', None)

            # Source the NixOS environment config.
            ${lib.optionalString (
              osConfig.system.build.setEnvironment or null != null
            ) "source-bash ${osConfig.system.build.setEnvironment}"}

            # Restore xonsh's ls alias, overriding that from Bash (if any).
            if _ls_alias is not None:
                aliases['ls'] = _ls_alias
            del _ls_alias

        ${lib.optionalString cfg.bashCompletion.enable "$BASH_COMPLETIONS = '${bashCompletionPath}'"}
        ${lib.optionalString cfg.fishCompletion.enable "xontrib load fish_completer"}

        ${cfg.config}
      '';

      home.packages = [ finalPackage ];
    })
    (lib.mkIf (cfg.enable && cfg.fishCompletion.enable) {
      programs.fish.enable = true;
      programs.xonsh.bashCompletion.enable = false;
      programs.xonsh.extraPackages =
        ps: with ps; [
          xonsh.xontribs.xontrib-fish-completer
        ];
    })
  ];
}
