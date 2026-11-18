{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.remapper;
  json = pkgs.formats.json { };
  # Each plugin that settings.plugins configures is installed.
  package = cfg.package.withPlugins (
    ps: map (name: ps.${name}) (lib.attrNames cfg.settings.plugins or { })
  );
  # The daemon validates the file at build time: a typo fails the switch, not the service.
  checked = pkgs.runCommand "remapper.json" { raw = json.generate "remapper.json" cfg.settings; } ''
    ${lib.getExe package} --check --config "$raw"
    cp "$raw" $out
  '';
in
{
  options.services.remapper = {
    enable = lib.mkEnableOption "the numpad remote control (pkgs/remapper)";
    package = lib.mkPackageOption pkgs "remapper" { };
    settings = lib.mkOption {
      inherit (json) type;
      description = ''
        The configuration file. `plugins.<name>` configures and installs a
        plugin from `package.plugins`; its actions are then valid in
        `bindings`. pkgs/remapper/core/src/remapper/config.py is the schema.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.remapper = {
      Unit = {
        Description = "Numpad remote control";
        # volumectl and pw-play act on the session's PipeWire.
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${lib.getExe package} --verbose --config ${checked}";
        Restart = "always";
        RestartSec = 2;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
}
