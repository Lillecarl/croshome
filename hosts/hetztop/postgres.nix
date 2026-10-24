# The database the apps on this host share.
#
# One server, one role per app, and no address off this machine: it listens on
# the unix socket and on 127.0.0.1, and the firewall never opens 5432. An app
# that runs as a systemd service here reaches it over the socket or over
# loopback; a container needs `--network=host` (or an explicit route out to a
# bridge address, which this file leaves closed on purpose).
#
# An app's password is set from a secret at every boot rather than written into
# the configuration as a hash. Two reasons: the configuration is in a public
# repository, and rotating a password should mean re-encrypting one file rather
# than re-hashing it and editing a second.
{ config, lib, pkgs, ... }:
{
  services.postgresql = {
    enable = true;

    # Nothing has to be said about `listen_addresses`: it follows
    # `enableTCPIP`, which is off, which means "localhost". Saying it anyway
    # would be a `mkForce` in a host file that reads as if the default were
    # wrong.
    enableTCPIP = false;

    # Peer over the socket, scram over loopback. The stock file trusts every
    # loopback connection, which would make the role passwords decorative for
    # anything already running on this machine -- and agents do run here.
    #
    # `authentication` is a line block, so NixOS appends its own default lines
    # after these rather than replacing them. That is harmless only because
    # pg_hba matches top to bottom and the first match wins: these three come
    # first, so the stock `host all all 127.0.0.1/32 md5` below them is never
    # reached. Keep new lines above it.
    authentication = ''
      local all all peer
      host all all 127.0.0.1/32 scram-sha-256
      host all all ::1/128 scram-sha-256
    '';

    ensureDatabases = [ "app" ];
    ensureUsers = [
      {
        # The first app. Its password is set below, from agenix.
        name = "app";
        ensureDBOwnership = true;
      }
      {
        # The way in for a person: peer authentication maps this OS account to
        # this role, so `psql` as lillecarl is a superuser session and needs no
        # password and no `sudo -u postgres`.
        name = "lillecarl";
        ensureClauses.superuser = true;
      }
    ];
  };

  # The app role's password. Nothing reads it yet -- the app does not exist --
  # but the role does, and a role without one cannot log in over loopback.
  age.secrets.app-db-password = {
    file = ../../secrets/app-db-password.age;
  };

  systemd.services.postgresql-app-password = {
    description = "Set the app role's password from its agenix secret";
    wantedBy = [ "multi-user.target" ];
    after = [
      "postgresql.service"
      # agenix installs the secrets through activation scripts, and through
      # these units where sysusers is on. Ordering against a unit that does not
      # exist costs nothing.
      "agenix-install-secrets.service"
      "agenix-chown.service"
    ];
    requires = [ "postgresql.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    # The password reaches psql on stdin, not on a command line: `psql -c
    # "...password..."` would put it in /proc for every local user to read
    # while the statement runs. Reading the secret stays with root, and only
    # the statement itself runs as postgres, where peer authentication is
    # satisfied.
    script = ''
      printf "ALTER ROLE app PASSWORD '%s';\n" "$(cat ${config.age.secrets.app-db-password.path})" \
        | ${pkgs.util-linux}/bin/runuser -u postgres -- \
            ${config.services.postgresql.package}/bin/psql -v ON_ERROR_STOP=1 -tA -d postgres
    '';
  };
}
