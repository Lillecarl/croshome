# Names for services in development that listen on localhost only.
# `8080.<domain>` reaches 127.0.0.1:8080, and the names in `named` reach
# fixed ports.
#
# Two domains route the same way:
#
# - `dynhetz.internal`, plain HTTP. `.internal` is reserved for private use
#   (ICANN, 2024), so it never collides with a public name.
# - `dynhetz.lillecarl.com`, HTTPS, for what a browser allows only on a
#   secure origin: a phone installs pymux web as an app only from one. The
#   wildcard certificate comes from Let's Encrypt over a DNS-01 challenge in
#   Cloudflare, so no public record points here; dnsmasq below answers.
#
# Both halves listen only on the tunnel address, and ./wireguard.nix lets
# only the owner's own peers reach it. A peer reaches this through the -dev
# profile, which points DNS at the resolver below.
{ config, lib, ... }:
let
  # This host on wg-dynhetz (./wireguard.nix).
  tunnelV6 = "2a01:4f9:3071:11d7:e3::1";
  tunnelV4 = "10.101.0.1";
  domain = "dynhetz.internal";
  tlsDomain = "dynhetz.lillecarl.com";

  # Not pymux web's default 8080: pynixd's binary cache holds that port here
  # (./pynixd.nix). Run `pymux web --port 37816`.
  named = {
    pymux = 37816;
  };

  routes = domain: ''
    ${lib.concatStrings (
      lib.mapAttrsToList (name: port: ''
        @${name} host ${name}.${domain}
        handle @${name} {
          reverse_proxy 127.0.0.1:${toString port}
        }
      '') named
    )}
    @port header_regexp port Host ^([0-9]{1,5})\.${lib.escapeRegex domain}(:[0-9]+)?$
    handle @port {
      reverse_proxy 127.0.0.1:{re.port.1}
    }
    handle {
      respond "No such service. Use <port>.${domain} or one of: ${lib.concatStringsSep ", " (lib.attrNames named)}" 404
    }
  '';

  listenAddresses = [
    "[${tunnelV6}]"
    tunnelV4
  ];
in
{
  # Not unbound: its DNS64 answers an IPv4-only name with a 64:ff9b:: address,
  # and the -dev profile does not route that prefix.
  services.dnsmasq = {
    enable = true;
    resolveLocalQueries = false;
    settings = {
      # The tunnel addresses only appear when wireguard-dynhetz runs;
      # bind-dynamic picks them up then. bind-interfaces would fail at boot.
      bind-dynamic = true;
      listen-address = [
        tunnelV6
        tunnelV4
      ];
      # AAAA only. The -dev profile has no IPv4, so an A answer sends the
      # client to a 10.101 address over its normal network first.
      address = [
        "/${domain}/${tunnelV6}"
        "/${tlsDomain}/${tunnelV6}"
      ];
      # Everything else goes to the host's own resolver, read from
      # /etc/resolv.conf (systemd-resolved).
      domain-needed = true;
      bogus-priv = true;
    };
  };

  # A token for Cloudflare's API: DNS Edit and Zone Read on lillecarl.com.
  sops.secrets.cloudflare-dns-token = { };

  security.acme = {
    acceptTerms = true;
    certs.${tlsDomain} = {
      domain = "*.${tlsDomain}";
      email = "git@lillecarl.com";
      dnsProvider = "cloudflare";
      credentialFiles.CLOUDFLARE_DNS_API_TOKEN_FILE = config.sops.secrets.cloudflare-dns-token.path;
      # lego waits for the TXT record through this resolver. The host's
      # (Hetzner's, via resolved) kept the challenge name as missing for the
      # zone's negative TTL, and the first order timed out after 2 minutes.
      dnsResolver = "1.1.1.1:53";
    };
  };

  services.caddy = {
    enable = true;
    globalConfig = "auto_https off";
    virtualHosts."http://*.${domain}" = {
      inherit listenAddresses;
      logFormat = "output file /var/log/caddy/access-dev.log";
      extraConfig = routes domain;
    };
    virtualHosts."https://*.${tlsDomain}" = {
      inherit listenAddresses;
      useACMEHost = tlsDomain;
      logFormat = "output file /var/log/caddy/access-dev.log";
      extraConfig = routes tlsDomain;
    };
  };

  # Caddy cannot bind an address that does not exist yet.
  systemd.services.caddy = {
    after = [ "wireguard-dynhetz.service" ];
    wants = [ "wireguard-dynhetz.service" ];
  };
}
