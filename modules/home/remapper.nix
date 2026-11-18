{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.remapper;
  json = pkgs.formats.json { };
in
{
  options.services.remapper = {
    enable = lib.mkEnableOption "the numpad remote control (pkgs/remapper)";
    package = lib.mkPackageOption pkgs "remapper" { };
    settings = lib.mkOption {
      inherit (json) type;
      description = "The configuration file; `Config` in pkgs/remapper/src/remapper/config.py is its schema.";
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
        ExecStart = "${lib.getExe cfg.package} --verbose --config ${json.generate "remapper.json" cfg.settings}";
        Restart = "always";
        RestartSec = 2;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
}
