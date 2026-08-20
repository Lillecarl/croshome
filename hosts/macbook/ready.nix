{
  config,
  pkgs,
  ...
}:
let
  user = config.system.primaryUser;

  # A system daemon can finish before launchd has created the user's Aqua
  # domain, so it cannot truthfully announce GUI readiness. Wait in that domain
  # for the two graphical agents instead.
  announce = pkgs.writeShellScript "cande-announce" ''
    set -eu
    uid=$(id -u -- ${user})
    for ((attempt = 0; attempt < 30; attempt++)); do
      aerospace=$(/bin/launchctl print "gui/$uid/org.nixos.aerospace" 2>/dev/null || true)
      borders=$(/bin/launchctl print "gui/$uid/org.nixos.jankyborders" 2>/dev/null || true)
      if [[ $aerospace == *"state = running"* && $borders == *"state = running"* ]]; then
        /usr/bin/osascript \
          -e 'display dialog "Session ready" with title "nix-darwin" buttons {"OK"} default button "OK" giving up after 4' \
          >/dev/null 2>&1 || true
        exit 0
      fi
      sleep 1
    done
  '';
in
{
  launchd.user.agents.session-ready = {
    serviceConfig = {
      ProgramArguments = [ "${announce}" ];
      RunAtLoad = true;
      KeepAlive = false;
    };
  };
}
