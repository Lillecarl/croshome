# Remote access to dynhetz and the lab behind it, over OpenVPN.
#
# Two server instances, one on udp/1194 and one on tcp/443 for whichever
# client is behind a firewall that blocks outbound UDP or anything but
# port 443 -- the client config lists all remotes and falls back
# automatically. They are genuinely separate `mode server` processes with
# their own address pools: two independent server instances cannot share
# one pool without risking the same address handed to two different
# clients, one on each protocol. The trade-off is that a client connected
# over TCP cannot reach one connected over UDP through this VPN directly
# (different pools, no route between them) -- an acceptable gap given only
# one of the two is ever actually needed at a time in practice.
#
# IPv6-only inside the tunnel. Each instance serves a /80 carved out of
# dynhetz's routed /64 (2a01:4f9:3071:11d7::/64 -- see the allocation table
# in ./wireguard.nix): udp gets ::e0::/80, tcp gets ::e1::/80. Hetzner
# routes the whole /64 to this host rather than treating it as a shared
# segment, so the kernel's connected routes for those /80s carry the
# traffic with no proxy-NDP and no NAT, the same way they already do for
# the pod and VM bridges. Both instances push a route for the entire /64,
# so a client reaches the host itself, the Kubernetes pods (::b0::/80),
# the KubeVirt VMs (::c0::/80) and the guest clusters (::d0::/80) through
# the tunnel. There is deliberately no IPv4 inside the tunnel: no `server`
# directive, no pushed IPv4 route.
#
# The transport itself stays dual-stack (`proto udp` / `tcp-server`,
# without a 4/6 suffix): a client on an IPv4-only network can still bring
# the tunnel up over IPv4 and get IPv6 inside it. The client config
# therefore lists both the IPv4 and the IPv6 address as remotes.
#
# Authentication is the machine's own users via PAM, on top of the
# certificate: the plugin checks the username/password against the `login`
# PAM service (which exists on every NixOS machine and reads the system
# user database -- no separate PAM service to define, and the plugin only
# calls the auth/account stacks so login's session modules never run),
# while the certificate check stays exactly as it was. Both have to
# succeed. `username-as-common-name` names the PAM user rather than the
# shared certificate's CN in the status table and the logs, which is what
# tells two users apart while they share one client certificate.
# `duplicate-cn` stays for the same reason it was here before: there is
# still one shared client certificate.
#
# The PKI is self-signed and generated once on the machine itself, kept
# out of the Nix store (world readable) and out of the repo. To start over,
# delete /var/lib/openvpn-oob and rerun.
{ pkgs, lib, ... }:
let
  nodeIPv4 = "37.27.129.237";
  nodeIPv6 = "2a01:4f9:3071:11d7::2";

  # The whole routed /64, pushed to clients so everything behind this host
  # is reachable through the tunnel.
  lanPrefix = "2a01:4f9:3071:11d7::/64";

  # One /80 per server instance out of ./wireguard.nix's allocation table.
  # Separate pools because the two instances cannot share one.
  udpPool = "2a01:4f9:3071:11d7:e0::/80";
  tcpPool = "2a01:4f9:3071:11d7:e1::/80";

  pamPlugin = "${pkgs.openvpn}/lib/openvpn/plugins/openvpn-plugin-auth-pam.so";

  # Shared by both instances: everything except the device, the transport
  # and the pool. Kept in one place so the two servers cannot drift apart
  # on authentication or pushed routes.
  common = ''
    mode server
    tls-server
    duplicate-cn

    plugin ${pamPlugin} login
    username-as-common-name

    push "route-ipv6 ${lanPrefix}"
    client-to-client

    ca /var/lib/openvpn-oob/pki/ca.crt
    cert /var/lib/openvpn-oob/pki/server.crt
    key /var/lib/openvpn-oob/pki/server.key
    dh none
    tls-crypt /var/lib/openvpn-oob/pki/ta.key

    keepalive 10 60
    persist-key
    persist-tun
    verb 3
  '';
in
{
  # Self-signed CA + one server cert + one shared client cert, generated
  # once on the machine itself and kept out of the Nix store (world
  # readable) and out of the repo.
  systemd.services.openvpn-oob-pki = {
    description = "Generate the OpenVPN OOB server's self-signed PKI";
    wantedBy = [
      "openvpn-oob.service"
      "openvpn-oob-tcp.service"
    ];
    before = [
      "openvpn-oob.service"
      "openvpn-oob-tcp.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [
      pkgs.openssl
      pkgs.openvpn
    ];
    script = ''
      set -euo pipefail
      pki=/var/lib/openvpn-oob/pki
      install -d -m 0700 "$pki"
      cd "$pki"

      # Skips regenerating anything that already exists, so a rebuild
      # doesn't invalidate the client cert every client already has
      # installed -- but still falls through past this, unconditionally,
      # to reassemble oob-client.ovpn below on every run, cheaply, in
      # case it's ever missing without the certs themselves being touched.
      if [ ! -f ca.crt ]; then
        openssl ecparam -name prime256v1 -genkey -noout -out ca.key
        openssl req -x509 -new -key ca.key -sha256 -days 3650 \
          -subj "/CN=dynhetz-oob-ca" -out ca.crt

        openssl ecparam -name prime256v1 -genkey -noout -out server.key
        openssl req -new -key server.key -subj "/CN=dynhetz-oob-server" -out server.csr
        openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
          -days 3650 -sha256 \
          -extfile <(printf 'extendedKeyUsage=serverAuth\nkeyUsage=digitalSignature,keyEncipherment\n') \
          -out server.crt
        rm -f server.csr

        # Shared by all clients -- one identity is fine because PAM names
        # the user separately (see username-as-common-name above).
        openssl ecparam -name prime256v1 -genkey -noout -out client.key
        openssl req -new -key client.key -subj "/CN=oob-client" -out client.csr
        openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
          -days 3650 -sha256 \
          -extfile <(printf 'extendedKeyUsage=clientAuth\nkeyUsage=digitalSignature\n') \
          -out client.crt
        rm -f client.csr

        # Wraps the TLS handshake itself, not just post-handshake auth --
        # drops unauthenticated probes silently rather than replying,
        # which matters more than usual for a port that's deliberately
        # reachable from anywhere.
        openvpn --genkey secret ta.key

        chmod 600 ./*.key
        chmod 644 ./*.crt
      fi

      # A single, self-contained .ovpn for the shared client identity --
      # ca/cert/key/tls-crypt embedded inline (OpenVPN's own <tag> blocks)
      # rather than four separate files plus a hand-typed config. Every
      # client imports the same file, then authenticates as its own system
      # user: `auth-user-pass` prompts for the PAM username/password on
      # each connect. Written here, at activation, because this service
      # already runs as root with the key material on hand -- no separate
      # script for someone to remember to run with their own sudo later.
      cat <<EOF > oob-client.ovpn
      client
      dev tun
      remote ${nodeIPv4} 1194 udp
      remote ${nodeIPv6} 1194 udp
      remote ${nodeIPv4} 443 tcp
      remote ${nodeIPv6} 443 tcp
      resolv-retry infinite
      nobind
      persist-key
      persist-tun
      remote-cert-tls server
      auth-user-pass
      verb 3

      <ca>
      $(cat ca.crt)
      </ca>
      <cert>
      $(cat client.crt)
      </cert>
      <key>
      $(cat client.key)
      </key>
      <tls-crypt>
      $(cat ta.key)
      </tls-crypt>
      EOF
      chmod 600 oob-client.ovpn
    '';
  };

  services.openvpn.servers.oob = {
    config = ''
      dev tun-oob
      dev-type tun
      proto udp
      port 1194

      server-ipv6 ${udpPool}

      ${common}
    '';
  };

  services.openvpn.servers.oob-tcp = {
    config = ''
      dev tun-oob-tcp
      dev-type tun
      proto tcp-server
      port 443

      server-ipv6 ${tcpPool}

      ${common}
    '';
  };

  # The tunnel interfaces terminate on this host, so traffic from clients
  # to the /64 leaves through them by the pushed route and comes back the
  # same way. Trusted, like cni0 in ./kubernetes/default.nix: that is what
  # lets a client reach the API server, the pods and the VMs without
  # opening each port individually -- and nothing on these interfaces can
  # come from anywhere but an authenticated client.
  networking.firewall.trustedInterfaces = [
    "tun-oob"
    "tun-oob-tcp"
  ];

  # Forwarding for the pushed /64. Stated here rather than relied on from
  # ./kubernetes/runtime.nix, so this file works if that one ever goes away.
  boot.kernel.sysctl = {
    "net.ipv6.conf.all.forwarding" = lib.mkDefault 1;
    "net.ipv6.conf.default.forwarding" = lib.mkDefault 1;
  };

  networking.firewall.allowedUDPPorts = [ 1194 ];
  networking.firewall.allowedTCPPorts = [ 443 ];
}
