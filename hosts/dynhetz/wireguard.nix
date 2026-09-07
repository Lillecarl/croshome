# General-purpose access to dynhetz itself -- not OOB provisioning
# (../openvpn-oob.nix is the separate, temporary thing for that), and not
# scoped to any particular service: this just gets a peer (today,
# lillecarl's MacBook) a real address dynhetz will route to, for whatever
# dynhetz ends up hosting.
#
# IPv6 is the point, alongside the private IPv4 range every VPN like this
# needs anyway: Hetzner routes dynhetz's whole /64
# (2a01:4f9:3071:11d7::/64) to its link-local gateway (see
# ../default.nix's systemd.network.networks."10-eth0" and its own
# comment) rather than treating it as a shared segment needing NDP proxy
# -- confirmed against Hetzner's own docs, not assumed, since getting
# this wrong would mean traffic for the carved-out range silently never
# arrives. That means a sub-range of it can just be assigned to another
# local interface and routed normally, no proxy-ndp/ndppd needed: giving
# wg-dynhetz 2a01:4f9:3071:11d7:90::1/112 makes the kernel's own
# more-specific connected route carry anything for that /112 there
# automatically, on top of the /64 that already arrives at dynhetz
# unconditionally. Once a peer has a real address in that block, it can
# reach any service dynhetz binds anywhere in the /64 directly -- same
# machine, different interface, no forwarding or NAT involved, since the
# traffic terminates on dynhetz itself rather than passing through it.
#
# Peers deliberately do NOT get a pushed default route (0.0.0.0/0 /
# ::/0) -- only 10.100.0.0/24 and the /64 are routed through the tunnel,
# so this only ever carries traffic to dynhetz itself, never general
# internet traffic.
#
# Sub-range allocation within the /64, so future networks don't collide
# with this one by accident: each network gets its own /80, chosen by
# the fifth hextet (the first 16 bits after the routed /64).
#
#   2a01:4f9:3071:11d7:0090::/80  -- wg-dynhetz (this file). Only the
#                                    /112 at ::90:: is actually in use.
#   2a01:4f9:3071:11d7:00a0::/80  -- the libvirt lab bridge
#                                    (virbr-nixlab2), for IPv6-only lab
#                                    VMs. In use: ../dynhetz/libvirt-lab-net.nix.
#   2a01:4f9:3071:11d7:00b0::/80  -- pods of the single-node Kubernetes
#                                    cluster on this host, on cni0. In
#                                    use: ../dynhetz/kubernetes.nix. That
#                                    cluster's Services are ULA
#                                    (fd00:10:96::/108) and take nothing
#                                    from here, because a ClusterIP never
#                                    leaves the node.
#
# The next network after that takes ::00c0::/80, and so on.
#
# Not a systemd.network.netdevs entry like ../openvpn-oob.nix's dummy/
# bridge devices: WireGuardPeer's PublicKey has no file-based option in
# systemd's own netdev format (unlike PrivateKeyFile/PresharedKeyFile),
# so it would have to be a literal value baked into this file at Nix
# eval time -- meaning either committing key material to the repo, or a
# separate script writing back into the checkout, neither of which fits
# "generated once, locally, kept out of the repo" (see ../openvpn-oob.nix
# for the same reasoning applied to its PKI). Configuring the interface
# imperatively via `wg set`, entirely at activation time, sidesteps that.
{ pkgs, ... }:
{
  systemd.services.wireguard-dynhetz = {
    description = "Bring up the dynhetz WireGuard interface (general access)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [
      pkgs.wireguard-tools
      pkgs.iproute2
    ];
    script = ''
      set -euo pipefail
      dir=/var/lib/wireguard-dynhetz
      install -d -m 0700 "$dir"
      cd "$dir"

      umask 077
      if [ ! -f server.key ]; then
        wg genkey > server.key
        wg pubkey < server.key > server.pub
      fi
      # Only one peer today (lillecarl's MacBook), sharing the same
      # "generate once, hand out the whole client config" approach as
      # ../openvpn-oob.nix -- unlike that file's shared OpenVPN cert
      # though, a second real peer here would need its own keypair and
      # its own `wg set ... peer` line, WireGuard has no equivalent of a
      # certificate CN multiple peers can share.
      if [ ! -f client.key ]; then
        wg genkey > client.key
        wg pubkey < client.key > client.pub
      fi

      ip link show wg-dynhetz >/dev/null 2>&1 || ip link add wg-dynhetz type wireguard
      wg set wg-dynhetz \
        private-key server.key \
        listen-port 51820 \
        peer "$(cat client.pub)" \
        allowed-ips 10.100.0.2/32,2a01:4f9:3071:11d7:90::2/128

      ip addr replace 10.100.0.1/24 dev wg-dynhetz
      ip -6 addr replace 2a01:4f9:3071:11d7:90::1/112 dev wg-dynhetz
      ip link set wg-dynhetz up

      # A ready-to-import wg-quick config -- reassembled every run
      # (cheap), even once the keys themselves are already in place, so
      # it self-heals if it's ever deleted without the keys being
      # touched.
      cat <<EOF > client.conf
      [Interface]
      PrivateKey = $(cat client.key)
      Address = 10.100.0.2/24, 2a01:4f9:3071:11d7:90::2/112

      [Peer]
      PublicKey = $(cat server.pub)
      Endpoint = 37.27.129.237:51820
      AllowedIPs = 10.100.0.0/24, 2a01:4f9:3071:11d7::/64
      PersistentKeepalive = 25
      EOF
      chmod 600 client.conf
    '';
  };

  networking.firewall.allowedUDPPorts = [ 51820 ];
}
