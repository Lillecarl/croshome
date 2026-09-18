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
# connects by name (dynhetz.ch.se.eu.org), whose records carry both the
# IPv4 and the IPv6 address; OpenVPN tries every address a name resolves
# to, so the name alone covers the dual-stack fallback. It is followed by
# the IPv4 literal anyway, because a connect by name needs a resolver and
# the one this tunnel pushes stops answering the moment the tunnel drops --
# see `nodeIPv4` below for the full circle.
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
# delete /var/lib/openvpn-lab; the next activation regenerates it.
{ pkgs, lib, ... }:
let
  # The client config connects by name first. Both records point here: the A
  # at nodeIPv4, the AAAA at nodeIPv6. An IP move is then a DNS update, and
  # the literals below only have to be corrected before the next activation.
  vpnName = "dynhetz.ch.se.eu.org";

  # Literal fallback remotes, listed after the name.
  #
  # A connect by name needs a resolver, and the tunnel pushes one that only
  # answers through the tunnel (`dhcp-option DNS ${nodeIPv6}`, below). After
  # an unclean disconnect the client keeps that resolver, so the name it
  # needs to reconnect cannot be resolved -- and `redirect-gateway ipv6`
  # leaves ::/1 and 8000::/1 behind pointing at a dead tun, so the query
  # does not even leave. `resolv-retry infinite` then spins forever: it
  # rides out a slow resolver, not a blackholed one.
  #
  # The literals break that circle. OpenVPN walks the remote list in order,
  # so the name still wins whenever DNS works.
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

  # The dynamist accounts, from the same directory dynusers.nix builds users
  # from: the client config gets a copy in each of their homes.
  dynUserNames = builtins.attrNames (
    lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./dynusers)
  );

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

    # Default-route IPv6 through the tunnel: the client sends all v6 traffic
    # here, and it leaves for the internet from this host. No NAT is needed
    # for that -- the client pools are world-routable space Hetzner already
    # routes here, so replies find their way back and forwarding carries
    # them to the tunnel. To egress v4 locally, or everything locally,
    # disable the VPN.
    #
    # `!ipv4` is not decoration. The `ipv6` flag means "redirect IPv6 *as
    # well*": in openvpn 2.6.21 `options.c` it only sets RG_REROUTE_GW on
    # the v6 route list, and leaves RG_ENABLE set on the v4 one. `!ipv4` is
    # what clears the v4 half, and `ipv6 !ipv4` is the documented pair for
    # redirecting v6 only (doc/man-sections/vpn-network-options.rst).
    #
    # Without it the client also attempts a v4 default redirect, which this
    # tunnel cannot satisfy: it carries `ifconfig-ipv6` only, and the server
    # logs `IPv4=(Not enabled)` for every client. `route.c` then warns
    # "unable to redirect IPv4 default gateway -- VPN gateway parameter
    # (--route-gateway or --ifconfig) is missing".
    #
    # A macOS client with `redirect-gateway ipv6` had no v6 routes at all,
    # with the tunnel up and the data path healthy both ways. The generic
    # `add_routes` path only warns on the v4 failure and still reaches the
    # v6 routes, so why macOS ends up with none of them is NOT established
    # here -- the platform route code is the place to look if it recurs.
    # Asking for a v4 redirect on a tunnel with no v4 is wrong either way.
    #
    # The routes it installs are 2000::/4 and 3000::/4, which cover the v6
    # unicast space and beat ::/0 on prefix length without replacing it.
    push "redirect-gateway ipv6 !ipv4"

    # DNS follows the tunnel: clients resolve through this host's own
    # resolver (see ../nat64.nix), so they get the same DNS64 answers pods
    # get -- an IPv4-only name answers with a 64:ff9b::/96 address Jool then
    # translates, which is the whole point of reaching the lab over v6. A
    # literal address, so reaching it needs no bootstrap lookup.
    push "dhcp-option DNS ${nodeIPv6}"
    client-to-client

    # MTU discipline for the tunnel. tun-mtu 1400 caps what the kernel hands
    # the tunnel (so PMTUD reports 1400, never 1500) and mssfix keeps TCP
    # small. v6 inside over v4-or-v6 transport is the worst case at ~90
    # bytes of overhead, so outer datagrams stay under ~1490 on a standard
    # 1500 path with no IP fragmentation involved. Notably absent: fragment.
    # It is not negotiated or pushed, so it must match on both ends by hand
    # -- and it cannot: it is a fatal options error under any TCP proto, and
    # the client file below serves both. A one-sided fragment garbles the
    # channel into "unknown IP version" noise and flaps the tunnel.
    tun-mtu 1400
    mssfix 1360

    ca /var/lib/openvpn-lab/pki/ca.crt
    cert /var/lib/openvpn-lab/pki/server.crt
    key /var/lib/openvpn-lab/pki/server.key
    dh none
    tls-crypt /var/lib/openvpn-lab/pki/ta.key

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
  #
  # This is an activation script rather than a systemd oneshot on purpose:
  # activation runs at every switch and boot, so a change to the template
  # below is in every user's home after the same switch that deployed it.
  # The oneshot it replaces ran only at boot or on an explicit restart, and
  # a switch never reruns a failed one -- which is how a config change once
  # sat undistributed for days behind a service that looked green.
  #
  # The subshell keeps the `cd` from leaking into the activation scripts
  # that run after this one.
  system.activationScripts.openvpn-lab-pki = ''
      (
      set -euo pipefail

      # Renamed from openvpn-oob: carry the PKI across once, so already
      # enrolled clients keep working. A fresh machine never has the old
      # directory and skips this.
      if [ ! -d /var/lib/openvpn-lab ] && [ -d /var/lib/openvpn-oob ]; then
        mv /var/lib/openvpn-oob /var/lib/openvpn-lab
      fi

      pki=/var/lib/openvpn-lab/pki
      install -d -m 0700 "$pki"
      cd "$pki"

      # Skips regenerating anything that already exists, so an activation
      # doesn't invalidate the client cert every client already has
      # installed -- but still falls through past this, unconditionally,
      # to reassemble lab-client.ovpn below on every run, cheaply, in
      # case it's ever missing without the certs themselves being touched.
      if [ ! -f ca.crt ]; then
        ${pkgs.openssl}/bin/openssl ecparam -name prime256v1 -genkey -noout -out ca.key
        ${pkgs.openssl}/bin/openssl req -x509 -new -key ca.key -sha256 -days 3650 \
          -subj "/CN=dynhetz-lab-ca" -out ca.crt

        ${pkgs.openssl}/bin/openssl ecparam -name prime256v1 -genkey -noout -out server.key
        ${pkgs.openssl}/bin/openssl req -new -key server.key -subj "/CN=dynhetz-lab-server" -out server.csr
        ${pkgs.openssl}/bin/openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
          -days 3650 -sha256 \
          -extfile <(printf 'extendedKeyUsage=serverAuth\nkeyUsage=digitalSignature,keyEncipherment\n') \
          -out server.crt
        rm -f server.csr

        # Shared by all clients -- one identity is fine because PAM names
        # the user separately (see username-as-common-name above).
        ${pkgs.openssl}/bin/openssl ecparam -name prime256v1 -genkey -noout -out client.key
        ${pkgs.openssl}/bin/openssl req -new -key client.key -subj "/CN=lab-client" -out client.csr
        ${pkgs.openssl}/bin/openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
          -days 3650 -sha256 \
          -extfile <(printf 'extendedKeyUsage=clientAuth\nkeyUsage=digitalSignature\n') \
          -out client.crt
        rm -f client.csr

        # Wraps the TLS handshake itself, not just post-handshake auth --
        # drops unauthenticated probes silently rather than replying,
        # which matters more than usual for a port that's deliberately
        # reachable from anywhere.
        ${pkgs.openvpn}/bin/openvpn --genkey secret ta.key

        chmod 600 ./*.key
        chmod 644 ./*.crt
      fi

      # A single, self-contained .ovpn for the shared client identity --
      # ca/cert/key/tls-crypt embedded inline (OpenVPN's own <tag> blocks)
      # rather than four separate files plus a hand-typed config. Every
      # client imports the same file, then authenticates as its own system
      # user: `auth-user-pass` prompts for the PAM username/password on
      # each connect. The copy in each home is distributed by the tmpfiles
      # rules below.
      cat <<EOF > lab-client.ovpn
      client
      dev tun
      remote ${vpnName} 1194 udp
      remote ${nodeIPv4} 1194 udp
      remote ${vpnName} 443 tcp
      remote ${nodeIPv4} 443 tcp
      resolv-retry infinite
      nobind
      persist-key
      persist-tun
      remote-cert-tls server
      auth-user-pass
      verb 3

      # Match the server's MTU discipline (see above): tun-mtu and mssfix are
      # safe under either transport. fragment is deliberately absent: it is
      # a fatal options error under TCP, so listing it here would break the
      # tcp/443 fallback this file's remotes promise.
      tun-mtu 1400
      mssfix 1360

      # DNS arrives as a server push (dhcp-option DNS). The official clients
      # and NetworkManager apply it themselves; a plain CLI client on Linux
      # needs update-resolv-conf or systemd-resolved handling to honor it.

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
      chmod 600 lab-client.ovpn
      )
  '';

  # One copy per account, so nobody needs root to fetch it. The file still
  # carries the shared client key and the tls-crypt key -- a copy in a home
  # is acceptable because connecting also needs that user's own PAM
  # credentials; possession alone is not access. lillecarl is in the list
  # too: the admin account uses the VPN, and its copy is the one an agent
  # can verify without root. tmpfiles runs at every activation and boot,
  # replaces a copy left stale by a regenerated PKI, and restores one a
  # user deleted.
  systemd.tmpfiles.rules = map (user: ''
    C /home/${user}/lab-client.ovpn 0600 ${user} users - /var/lib/openvpn-lab/pki/lab-client.ovpn
  '') (dynUserNames ++ [ "lillecarl" ]);

  services.openvpn.servers.lab = {
    config = ''
      dev tun-lab
      dev-type tun
      proto udp
      port 1194

      server-ipv6 ${udpPool}

      ${common}
    '';
  };

  services.openvpn.servers.lab-tcp = {
    config = ''
      dev tun-lab-tcp
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
    "tun-lab"
    "tun-lab-tcp"
  ];

  # Forwarding for the pushed /64. Stated here rather than relied on from
  # ./kubernetes/runtime.nix, so this file works if that one ever goes away.
  boot.kernel.sysctl = {
    "net.ipv6.conf.all.forwarding" = lib.mkDefault 1;
    "net.ipv6.conf.default.forwarding" = lib.mkDefault 1;
  };

  # trustedInterfaces above opens INPUT and nothing else, so it lets a
  # client reach this host and leaves it unable to reach anything behind
  # it. ./wireguard.nix already records the same finding for wg-dynhetz:
  # "trustedInterfaces is INPUT-only on the iptables backend and opens no
  # forwarding". The sysctls are necessary and not sufficient.
  #
  # Checked in the generated script: every FORWARD rule on this host names
  # wg-dynhetz, and the nixos-filter-forward chain holds `iptables` rules
  # only, so its v6 side is empty. Nothing carried a client's packet past
  # this machine.
  #
  # Out of the tunnel is unconditional; back in is established traffic plus
  # the lab itself, so a pod or a VM can open a connection to a client
  # while the internet at large cannot -- the pools are globally routable
  # addresses, so FORWARD is the only thing standing in front of them.
  #
  # No MSS clamp here, unlike ./wireguard.nix: these clients are OpenVPN
  # peers, and `mssfix 1360` above already clamps them at the tunnel.
  networking.firewall.extraCommands =
    lib.concatMapStrings (dev: ''
      ip46tables -A FORWARD -i ${dev} -j ACCEPT
      ip46tables -A FORWARD -o ${dev} -m state --state ESTABLISHED,RELATED -j ACCEPT
      ip6tables  -A FORWARD -s ${lanPrefix} -o ${dev} -j ACCEPT
    '') [ "tun-lab" "tun-lab-tcp" ];

  networking.firewall.allowedUDPPorts = [ 1194 ];
  networking.firewall.allowedTCPPorts = [ 443 ];
}
