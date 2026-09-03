# Host-side prep for libvirt VMs that get real, individually-addressable
# IPv6 out of dynhetz's own /64. This file does NOT define the libvirt
# network itself -- that lives in Terraform, alongside the domains and
# their cloud-init/Talos user-data, using the `libvirt` Terraform
# provider (dmacvicar/terraform-provider-libvirt) over the local
# qemu:///system socket, since Terraform runs on dynhetz itself. This
# file only sets up what has to happen at the NixOS/kernel level first.
#
# Unlike ../wireguard.nix's carved-out range, which only ever terminates
# ON dynhetz (a WireGuard peer talking to a service dynhetz itself
# binds), traffic to a VM genuinely passes THROUGH dynhetz: in from
# eth0 (Hetzner routes the whole /64 here), out to whatever bridge the
# VM sits on. The kernel doesn't forward IPv6 between interfaces at all
# unless told to -- that's the one thing this file turns on.
#
# No firewall rule needed alongside it. Checked directly rather than
# assumed: dynhetz still uses the iptables firewall backend
# (config.networking.firewall.backend, confirmed with `nix eval` against
# this flake), and that backend's module never touches the FORWARD chain
# at all -- only the nftables backend's does, through
# networking.firewall.filterForward, which would be a silent no-op here.
# Nothing else in this repo sets a FORWARD policy either (dynhetz used
# to, through networking.nat, before that was dropped along with the
# bridge/TAP OOB design -- see ./openvpn-oob.nix's own history), so the
# kernel's default policy (ACCEPT) already lets forwarded traffic
# through once the sysctls below turn forwarding on at all. That means a
# VM is reachable on any port it opens, world-routable straight off the
# /64, exactly like dynhetz itself is today -- there's no host-level
# segmentation; each VM's own firewall (or a Kubernetes NetworkPolicy,
# once there's a cluster) is the only boundary. Revisit this (switch the
# firewall backend to nftables, turn filterForward on) if that stops
# being an acceptable trade-off.
#
# IPv6 allocation, for whoever writes the Terraform:
#
#   - dynhetz's routed prefix is 2a01:4f9:3071:11d7::/64.
#     ../wireguard.nix's own comment reserves each /80 sub-range within
#     it by the fifth hextet -- see the table there. Lab VMs get
#     2a01:4f9:3071:11d7:00a0::/80.
#
#   - Define the network as a libvirt_network resource with
#     `mode = "route"` (never "nat" -- these addresses are meant to be
#     reachable exactly like any other address in the /64, not hidden
#     behind one) and `addresses = ["2a01:4f9:3071:11d7:a0::/80"]`.
#     Route mode's own dnsmasq instance (one per libvirt network,
#     libvirt starts and owns it) hands out RA/DHCPv6 to whatever
#     attaches -- nothing to configure on the NixOS side for that.
#
#   - Give the network a fixed `bridge` name (e.g. "br-lab") instead of
#     letting libvirt pick virbrN -- keeps it predictable if this file
#     ever needs to reference the interface directly later.
#
#   - Both Talos and NixOS domains take their machine config /
#     configuration.nix through a `libvirt_cloudinit_disk` (NoCloud):
#     Talos's own `nocloud` platform reads that the same way any other
#     cloud-init-consuming OS would.
#
#   - A second lab network, if one's ever needed (say, an isolated
#     cluster with no WAN-reachable pods), takes the next reserved /80
#     in ../wireguard.nix's table (2a01:4f9:3071:11d7:00b0::/80) --
#     update that table when it happens.
{
  boot.kernel.sysctl = {
    "net.ipv6.conf.all.forwarding" = 1;
    # "all" only takes effect on interfaces that already exist at the
    # moment it's applied (boot, here). "default" is the template new
    # interfaces inherit at creation -- exactly the case for a libvirt
    # bridge Terraform brings up long after boot, at `terraform apply`
    # time.
    "net.ipv6.conf.default.forwarding" = 1;
  };
}
