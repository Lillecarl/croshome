# A temporary, deliberately hacky OpenVPN server: punches through
# restrictive firewalls to reach a small out-of-band provisioning network
# for new office gear -- not the office network itself, a separate L2
# domain from it.
#
# Plain routed TUN, not TAP/bridged L2: OpenVPN Connect (the official
# macOS client) is OpenVPN3-core, which dropped `dev tap` support
# entirely, on every platform, no config workaround exists -- and the
# only client that still can do TAP on macOS, Tunnelblick, needs its
# legacy system extension loaded, which on Apple Silicon means Recovery
# Mode, a lowered security policy, and several reboots, for a feature its
# own maintainers say is headed for removal around now anyway. That ruled
# out TAP for lillecarl's MacBook, and once the MacBook isn't on the same
# L2 segment as the MikroTik anyway, there's no reason to keep TAP for
# the MikroTik either: MNDP neighbor discovery and MAC-address WinBox
# only need to work from the first MikroTik to whatever else ends up
# plugged into the OOB switch, which is real, local L2 -- entirely
# outside this VPN hop. The VPN only ever has to get that first MikroTik
# (and the Mac) an IP on the OOB segment; it doesn't have to carry L2
# itself to do that.
#
# One shared TUN server subnet, 192.168.90.0/24, with client-to-client so
# the MikroTik and the Mac can reach each other and dynhetz's own
# 192.168.90.1 directly -- no bridge, no dummy interface, no NAT.
#
# A second server instance listens on tcp/443 too, for whichever client
# is behind a firewall that blocks outbound UDP or anything but port 443
# -- the client config lists both remotes and falls back automatically.
# It's a genuinely separate `mode server` process with its own address
# pool (192.168.91.0/24, not 192.168.90.0/24): two independent server
# instances can't share one pool without risking the same address handed
# to two different clients, one on each protocol. The trade-off is that
# a client connected over TCP can't reach one connected over UDP through
# this VPN directly (different subnets, no route between them) -- an
# acceptable gap given only one of the two is ever actually needed at a
# time in practice.
#
# Meant to come down once the gear is provisioned -- hence the shared
# "fixed" client credential (one certificate, used by both the MikroTik
# and the MacBook, rather than a real per-user database) and the
# self-signed, locally-generated PKI (nothing checked into the repo,
# nothing to rotate or revoke later, just delete /var/lib/openvpn-oob
# and rerun to start over).
{ pkgs, ... }:
{
  # Self-signed CA + one server cert + one shared client cert, generated
  # once on the machine itself and kept out of the Nix store (world
  # readable) and out of the repo (this is throwaway infrastructure with
  # no reason to have its key material committed anywhere).
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

        # Shared by both clients (the MikroTik and the MacBook) -- see the
        # top of this file for why one identity is fine here.
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
      # rather than four separate files plus a hand-typed config. Both
      # the MikroTik and the MacBook import the exact same file. Written
      # here, at activation, because this service already runs as root
      # with the key material on hand -- no separate script for someone
      # to remember to run with their own sudo later.
      cat <<EOF > oob-client.ovpn
      client
      dev tun
      remote 37.27.129.237 1194 udp4
      remote 37.27.129.237 443 tcp4
      resolv-retry infinite
      nobind
      persist-key
      persist-tun
      remote-cert-tls server
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
      proto udp4
      port 1194

      mode server
      tls-server
      duplicate-cn

      # subnet topology, not the legacy net30 pairs -- gives every client
      # a normal address within the /24 (dynhetz's own tun-oob lands on
      # .1) rather than a separate point-to-point /30 each, which is what
      # makes client-to-client routing between the MikroTik and the Mac
      # behave like a normal shared subnet instead of two disjoint links.
      topology subnet
      server 192.168.90.0 255.255.255.0
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
  };

  services.openvpn.servers.oob-tcp = {
    config = ''
      dev tun-oob-tcp
      dev-type tun
      proto tcp4-server
      port 443

      mode server
      tls-server
      duplicate-cn

      topology subnet
      server 192.168.91.0 255.255.255.0
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
  };

  networking.firewall.allowedUDPPorts = [ 1194 ];
  networking.firewall.allowedTCPPorts = [ 443 ];
}
