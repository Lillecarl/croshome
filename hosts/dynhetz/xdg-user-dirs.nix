# xdg-user-dirs with no desktop session. The package's autostart entry only
# runs inside a GUI, so headless ssh logins never update user-dirs.dirs or
# create missing directories. This user unit runs xdg-user-dirs-update at
# every login instead, for every account -- including the dynusers accounts,
# which home-manager does not manage. lillecarl's own directories are
# additionally declared in ../../home (xdg.userDirs), which wins for that
# user because home-manager sets enabled=False.
{ pkgs, lib, ... }:
{
  environment.systemPackages = [ pkgs.xdg-user-dirs ];

  systemd.user.services.xdg-user-dirs-update = {
    description = "Update XDG user directories";
    wantedBy = [ "default.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe pkgs.xdg-user-dirs;
    };
  };
}
