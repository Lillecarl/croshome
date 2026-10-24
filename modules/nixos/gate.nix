# The front door for the apps this host serves: one identity provider, and one
# gate in front of every app.
#
#   dex.<baseDomain>      the identity provider (dex)
#   <name>.<baseDomain>   an app, reachable only through its own gate
#
# A gate is an oauth2-proxy instance that acts as the app's public face, not a
# forward-auth checker behind some other proxy. That is the whole point of the
# shape: oauth2-proxy proxies the request itself, so the front door and the
# login are one thing and there is no second path to the app that skips it. A
# forward-auth setup would leave the app reachable for anyone who found its
# port and skipped the proxy.
#
# The app is therefore expected to listen on loopback, and nothing else. What
# makes it unreachable is that it has no public address, not that it is polite
# enough to check a header. Caddy is in the way only because it gets and
# renews the certificates by itself:
#
#   internet :443 -> Caddy (TLS, ACME) -> 127.0.0.1:<gate> -> oauth2-proxy
#     -> 127.0.0.1:<app> (or a static file, or dex)
#
# Everything the gates need from dex arrives through `idp`, and dex is this
# module's too: registering an app here registers its OAuth2 client there and
# hands it the same client secret the gate authenticates with.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.gate;

  # Gate ports come from the sorted app names, so two apps can never be handed
  # the same one and evaluation stays a pure function of the configuration. The
  # cost is that adding an app may move the port of every app after it in the
  # sort, and those gates restart; with a handful of apps that is cheaper than
  # a number in each app's block to get wrong.
  appNames = lib.sort builtins.lessThan (lib.attrNames cfg.apps);
  gatePort = name: 4180 + lib.lists.findFirstIndex (n: n == name) 0 appNames;

  # Cookie names have to be one token, and an app name is a DNS label: dashes
  # are legal there and not in a cookie name.
  cookieName = name: "_oauth2_" + lib.replaceStrings [ "-" ] [ "_" ] name;

  issuerUrl = "https://dex.${cfg.baseDomain}";

  # The one secret dex takes inline instead of by file: `staticPasswords.hash`
  # has no secretFile counterpart the way a client secret has. The generated
  # config keeps this string and a script replaces it under /run before dex
  # starts, so the store copy holds no secret -- see the dex service below.
  passwordHashPlaceholder = "@@password-hash@@";
in
{
  options.services.gate = {
    enable = lib.mkEnableOption "the identity-provider gate in front of hosted apps";

    baseDomain = lib.mkOption {
      type = lib.types.str;
      example = "snurr.example.com";
      description = ''
        The base every public name is built from: an app called `app` is served
        at `app.<baseDomain>` and the identity provider at `dex.<baseDomain>`.

        Both have to resolve to this host, which is the one thing this module
        cannot arrange. A wildcard record for `*.<baseDomain>` covers the apps
        as they are added; `dex.<baseDomain>` needs its own if it does not.
      '';
    };

    acmeEmail = lib.mkOption {
      type = lib.types.str;
      description = ''
        The address Let's Encrypt records for the account it issues the
        certificates under, and where it writes about an expiring one. Caddy
        asks for the certificate of each name separately, over HTTP-01, so
        port 80 has to stay reachable from outside.
      '';
    };

    cookieSecretFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        File holding the key every gate encrypts its session cookie with.
        oauth2-proxy reads the file's bytes as the key itself -- not base64
        decoded -- and refuses anything that is not 16, 24 or 32 bytes long, so
        write 32 random printable characters and no trailing newline. A base64
        string of 32 bytes is 44 characters and is rejected at startup.

        One file for every gate is deliberate at this size. Each gate names its
        cookie after its app, so the cookies do not collide, and a person who
        knows one of these keys knows all of them only because they already had
        to read this file to get it.
      '';
      example = "/run/agenix/gate-cookie-secret";
    };

    idp = {
      email = lib.mkOption {
        type = lib.types.str;
        description = ''
          The address the one local login is known by. It is an identifier, not
          a mailbox: dex never sends mail, it is what is typed into the login
          form and what oauth2-proxy compares an allowed-app list against.
        '';
      };

      username = lib.mkOption {
        type = lib.types.str;
        description = ''
          The username that goes with `idp.email`, and the user id dex puts in
          the ID token. Changing it changes what an app sees in
          `X-Forwarded-User` and nothing else -- in particular it does not
          invalidate a session.
        '';
      };

      passwordHashFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          File holding the bcrypt hash of the login password, as
          `mkpasswd -m bcrypt` prints it, and nothing else -- no trailing
          newline, since it is pasted into a YAML value.

          It is a secret and belongs on agenix's ramdisk. Changing it means
          re-encrypting the file and restarting dex; nothing here notices on
          its own.
        '';
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 5556;
        description = ''
          Port dex listens on, on loopback. Its public address is
          `https://dex.<baseDomain>` whatever this is; Caddy forwards here.
        '';
      };
    };

    apps = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            upstream = lib.mkOption {
              type = lib.types.str;
              description = ''
                What the gate forwards an authenticated request to, in
                oauth2-proxy's own syntax: `http://127.0.0.1:3000` for a
                service, `file:///path` for a directory of static files, or
                `static://200` for a placeholder that proves the gate works
                before the app behind it exists.

                A service here has to listen on loopback. Point this at
                anything else and the gate is decoration.
              '';
              example = "http://127.0.0.1:3000";
            };

            clientSecretFile = lib.mkOption {
              type = lib.types.path;
              description = ''
                File holding this app's OAuth2 client secret: 32 random bytes,
                or any string, with no trailing newline. dex reads it when the
                gate redirects a login here, and the gate reads it to redeem
                that login, so both sides must be given this same file.
              '';
              example = "/run/agenix/dex-client-app";
            };

            allowedEmails = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = ''
                Addresses allowed through this app's gate, one per line in the
                list. Empty means any account dex knows, which on a dex with
                one password is one person anyway.

                This is per app and not global on purpose: it is how a later
                account can be given one app without being given all of them.
              '';
              example = [ "someone@example.com" ];
            };
          };
        }
      );
      default = { };
      description = ''
        The apps on this host, by name. Each becomes `<name>.<baseDomain>`, an
        oauth2-proxy listening on a loopback port, and an OAuth2 client in dex.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.caddy = {
      enable = true;
      email = cfg.acmeEmail;
      # 80 and 443. 80 is not optional: it is where the ACME challenge is
      # answered, and where a plain http:// request gets told to use https.
      openFirewall = true;
      virtualHosts =
        {
          "dex.${cfg.baseDomain}".extraConfig = "reverse_proxy 127.0.0.1:${toString cfg.idp.port}";
        }
        // lib.mapAttrs' (
          name: _:
          lib.nameValuePair "${name}.${cfg.baseDomain}" {
            extraConfig = "reverse_proxy 127.0.0.1:${toString (gatePort name)}";
          }
        ) cfg.apps;
    };

    services.dex = {
      enable = true;
      settings = {
        issuer = issuerUrl;
        storage = {
          type = "sqlite3";
          config.file = "/var/lib/dex/dex.db";
        };
        web.http = "127.0.0.1:${toString cfg.idp.port}";
        # One password in dex's own database rather than a connector to
        # GitHub or Google: the account has to work when the network or the
        # upstream provider does not, and this host is the only thing that can
        # decide who gets in.
        enablePasswordDB = true;
        # dex asks every client to approve the identity it is handing over,
        # which for one person on one host is a click with nothing to decide.
        # This turns it off -- but oauth2-proxy hardcodes `approval_prompt=force`
        # in its authorization request, so the page still appears once per app
        # per login session. The setting is here for any other client.
        oauth2.skipApprovalScreen = true;
        staticPasswords = [
          {
            email = cfg.idp.email;
            hash = passwordHashPlaceholder;
            username = cfg.idp.username;
            userID = cfg.idp.username;
          }
        ];
        staticClients = lib.mapAttrsToList (name: app: {
          id = name;
          name = "${name}.${cfg.baseDomain}";
          secretFile = app.clientSecretFile;
          redirectURIs = [ "https://${name}.${cfg.baseDomain}/oauth2/callback" ];
        }) cfg.apps;
      };
    };

    systemd.services = {
      # sqlite, and dex runs as a dynamic user: without a state directory its
      # database has nowhere to live that survives a restart.
      #
      # The client secrets, and the password hash, are on agenix's ramdisk
      # rather than under /etc so that nothing is decrypted onto a disk.
      # dex's own sandbox sees /nix/store, /etc and not much else -- and needs
      # no more than that, because the substitution below happens with `+`,
      # outside the sandbox.
      #
      # `+` runs this as root, after the unit's own step that installs the
      # generated config with its placeholder still in place. The hash never
      # exists anywhere but /run/dex, and nothing in the store holds it.
      dex.serviceConfig = {
        StateDirectory = "dex";
        ExecStartPre = lib.mkAfter [
          "+${pkgs.replace-secret}/bin/replace-secret ${passwordHashPlaceholder} ${cfg.idp.passwordHashFile} /run/dex/config.yaml"
        ];
      };
    }
    // lib.mapAttrs' (
      name: app:
      lib.nameValuePair "gate-${name}" {
        description = "OAuth2 gate in front of ${name}.${cfg.baseDomain}";
        wantedBy = [ "multi-user.target" ];
        # oauth2-proxy fetches discovery from the issuer before it listens, so
        # dex must be up first; the restart loop covers the race anyway.
        after = [
          "network.target"
          "dex.service"
        ];
        wants = [ "dex.service" ];
        serviceConfig = {
          DynamicUser = true;
          Restart = "on-failure";
          RestartSec = 2;
          # Both secrets arrive as systemd credentials, readable by the unit
          # and by nothing else, rather than as paths on a command line.
          LoadCredential = [
            "client-secret:${app.clientSecretFile}"
            "cookie-secret:${cfg.cookieSecretFile}"
          ]
          ++ lib.optionals (app.allowedEmails != [ ]) [
            "allowed-emails:${
              pkgs.writeText "gate-${name}-allowed-emails" (lib.concatLines app.allowedEmails)
            }"
          ];
          ExecStart = lib.concatStringsSep " " (
            [
              "${lib.getExe pkgs.oauth2-proxy}"
              "--provider=oidc"
              "--oidc-issuer-url=${issuerUrl}"
              "--client-id=${name}"
              "--client-secret-file=%d/client-secret"
              "--cookie-secret-file=%d/cookie-secret"
              "--cookie-name=${cookieName name}"
              "--cookie-secure=true"
              "--http-address=127.0.0.1:${toString (gatePort name)}"
              "--upstream=${app.upstream}"
              "--redirect-url=https://${name}.${cfg.baseDomain}/oauth2/callback"
              # Caddy is in front, so the scheme and client address arrive in
              # X-Forwarded-* headers and are worth trusting: nothing but Caddy
              # can open this port. Naming the proxy explicitly matters --
              # `--reverse-proxy` alone trusts every connecting address to set
              # those headers, which undoes the point of setting them.
              "--reverse-proxy=true"
              "--trusted-proxy-ip=127.0.0.1/32"
              "--trusted-proxy-ip=::1/128"
              "--pass-user-headers=true"
              "--skip-provider-button=true"
              "--silence-ping-logging=true"
              # dex's password database does not mark the address verified,
              # and the only issuer this trusts is the dex above.
              "--insecure-oidc-allow-unverified-email=true"
            ]
            ++ lib.optionals (app.allowedEmails == [ ]) [ "--email-domain=*" ]
            ++ lib.optionals (app.allowedEmails != [ ]) [
              "--authenticated-emails-file=%d/allowed-emails"
            ]
          );
          NoNewPrivileges = true;
          PrivateTmp = true;
          PrivateDevices = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          LockPersonality = true;
          MemoryDenyWriteExecute = true;
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
          ];
          RestrictNamespaces = true;
          SystemCallArchitectures = "native";
        };
      }
    ) cfg.apps;
  };
}
