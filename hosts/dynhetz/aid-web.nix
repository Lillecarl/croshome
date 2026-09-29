# aid's web UI with a local dex as its OIDC provider, both on localhost only.
#
# A test setup, so its secrets are made on this machine rather than kept in
# ../../secrets: `aid-web-secrets` writes a client secret, a session secret and
# a login password to ~/.local/state/aid-web the first time it runs, and never
# again. Log in at http://127.0.0.1:37815 as `email` below, with the password in
# ~/.local/state/aid-web/password. Delete that directory to make new ones.
#
# dex keeps its state in memory: a restart logs everyone out, nothing else.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  email = "lillecarl@dynhetz.local";
  # Registered range, below the dynamic one (49152+), so an outgoing connection never takes them first.
  dexPort = 37814;
  webPort = 37815;
  issuer = "http://127.0.0.1:${toString dexPort}/dex";
  stateDir = "${config.xdg.stateHome}/aid-web";
  envFile = "${stateDir}/env";

  dexConfig = pkgs.writeText "aid-dex.json" (
    builtins.toJSON {
      inherit issuer;
      storage.type = "memory";
      web.http = "127.0.0.1:${toString dexPort}";
      oauth2.skipApprovalScreen = true;
      staticClients = [
        {
          id = "aid";
          name = "aid";
          secretEnv = "AID_OIDC_CLIENT_SECRET";
          redirectURIs = [ "http://127.0.0.1:${toString webPort}/auth/callback" ];
        }
      ];
      enablePasswordDB = true;
      staticPasswords = [
        {
          inherit email;
          hashFromEnv = "AID_DEX_PASSWORD_HASH";
          username = "lillecarl";
          userID = "a1d0a1d0-0000-4000-8000-000000000001";
        }
      ];
    }
  );

  makeSecrets = pkgs.writeShellApplication {
    name = "aid-web-secrets";
    runtimeInputs = [
      pkgs.coreutils
      (pkgs.python3.withPackages (p: [ p.bcrypt ]))
    ];
    text = ''
      dir=${lib.escapeShellArg stateDir}
      [ -e "$dir/env" ] && exit 0
      umask 077
      mkdir -p "$dir"
      password=$(head -c 18 /dev/urandom | base64 | tr -d '/+=')
      hash=$(printf '%s' "$password" | python3 -c 'import bcrypt, sys; print(bcrypt.hashpw(sys.stdin.buffer.read(), bcrypt.gensalt()).decode())')
      printf '%s\n' "$password" > "$dir/password"
      {
        printf 'AID_OIDC_CLIENT_SECRET=%s\n' "$(head -c 32 /dev/urandom | base64 | tr -d '/+=')"
        printf 'AID_WEB_SESSION_SECRET=%s\n' "$(head -c 32 /dev/urandom | base64 | tr -d '/+=')"
        printf 'AID_DEX_PASSWORD_HASH=%s\n' "$hash"
      } > "$dir/env.tmp"
      mv "$dir/env.tmp" "$dir/env"
    '';
  };
in
{
  services.aid.web = {
    enable = true;
    bind = "127.0.0.1:${toString webPort}";
    inherit issuer;
    allowEmails = [ email ];
    environmentFile = envFile;
    speechModel = config.services.aid.package.speechModel;
    # The same colours as the terminal: pymux's theme spelling.
    theme = config.programs.pymux.clientSettings.theme;
  };

  systemd.user.services = {
    aid-web-secrets = {
      Unit.Description = "aid web UI: make the local test secrets once";
      Service = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe makeSecrets;
      };
    };

    aid-dex = {
      Unit = {
        Description = "dex, the OIDC provider for aid's web UI";
        Requires = [ "aid-web-secrets.service" ];
        After = [ "aid-web-secrets.service" ];
      };
      Install.WantedBy = [ "default.target" ];
      Service = {
        ExecStart = "${lib.getExe pkgs.dex-oidc} serve ${dexConfig}";
        EnvironmentFile = envFile;
        Restart = "on-failure";
        RestartSec = "2s";
      };
    };

    # aid web fetches the issuer's discovery document on the first login, so dex has to be up.
    aid-web.Unit = {
      Requires = [
        "aid-web-secrets.service"
        "aid-dex.service"
      ];
      After = [
        "aid-web-secrets.service"
        "aid-dex.service"
      ];
    };
  };
}
