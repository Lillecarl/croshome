# NAT64 and DNS64, so an IPv6-only pod can reach an IPv4-only host.
#
# ./kubernetes gives every pod a real, world-routable IPv6 address and no
# IPv4 address at all. That is the right shape, and it costs the cluster
# github.com, ghcr.io, and every other host that never turned IPv6 on. Image
# pulls do not care, because containerd runs on the host and the host is
# dual-stack. Anything a pod dials itself does care.
#
# Two halves, and neither is useful alone:
#
#   DNS64   invents an IPv6 address for a name that only has an A record. The
#           address encodes the IPv4 one inside 64:ff9b::/96.
#   NAT64   receives traffic sent to 64:ff9b::/96, digs the IPv4 address back
#           out, and forwards it as real IPv4.
#
# DNS64 without NAT64 is worse than neither: it answers every A-only name with
# an address that goes nowhere, so a clean "no AAAA" failure becomes a
# connection timeout. They are one change and they ship together.
#
# 64:ff9b::/96 is the well-known prefix from RFC 6052. Nothing here has to
# allocate for it -- it is reserved globally for exactly this.
#
# Jool, and the patch it needs
# ----------------------------
# Jool is stateful NAT64: many pods share one IPv4 address the way a home
# router shares one, so this needs no second translation and no private pool.
#
# No released Jool builds against this host's 7.2.0 kernel. 4.1.14, which
# nixpkgs ships, and 4.1.15, the newest release, both fail the same way:
#
#   ERROR: modpost: "snmp_fold_field" [jool_common.ko] undefined!
#
# The kernel stopped exporting that symbol. NICMx/Jool#456 fixes it and is
# still open, so ../../pkgs/default.nix pins 4.1.15 plus that patch and moves
# the CLI with it. See that file for why both halves have to move together.
# All of it was decided by building rather than by reading release notes.
#
# Tayga was here first and is the fallback if that patch ever becomes
# unmaintainable: it is userspace, so it needs no module and no patch. The cost
# is that it is stateless -- one private IPv4 per pod out of a pool, plus a
# NAT44 masquerade behind it, so two translations and a ceiling near 254 pods.
# Jool needs neither.

{
  config,
  lib,
  pkgs,
  ...
}:
let
  # The cluster's own numbers, read rather than repeated. ./kubernetes declares
  # these as options for exactly this: the pod subnet appears in a firewall
  # rule, a CNI conflist, a kubeadm document and the access-control list below,
  # and one of those silently not matching the others is the failure this
  # avoids.
  inherit (config.dynhetz.kubernetes) podSubnet nodeIP;

  # The virtual machine subnet comes straight from the data file rather than
  # from an option, because ./kubernetes/network.nix is where both this host
  # and ../../kube read it -- see that file for why it is not a module.
  inherit (import ./kubernetes/network.nix) vmSubnet;

  # RFC 6052's well-known prefix. The one value both halves have to agree on:
  # DNS64 writes addresses into it, NAT64 listens for them.
  nat64Prefix = "64:ff9b::/96";

  # eth0's IPv4, named rather than discovered, for the same reason
  # ./kubernetes/default.nix names the node address: this host has several
  # addresses of each family and the right one is not the one a rule picks by
  # default.
  nodeIPv4 = "37.27.129.237";

  # Hetzner's own resolvers, IPv6 only. The same pair ./kubernetes/node.nix used to
  # hand pods directly, before this file put a DNS64 in front of them.
  upstream = [
    "2a01:4ff:ff00::add:1"
    "2a01:4ff:ff00::add:2"
  ];
in
{
  config = {
    # ── NAT64: 64:ff9b::/96 in, IPv4 out ─────────────────────────────────

    # The netfilter framework, which is the module's default and the reason no
    # route for 64:ff9b::/96 exists anywhere on this host. Jool hooks
    # PREROUTING, so a pod's packet is translated before the kernel ever looks
    # for a route to that prefix. nixpkgs' own NAT64 test is built the same
    # way: its router has no such route either.
    #
    # That has one consequence worth knowing. PREROUTING is not on the path of
    # locally generated traffic, so dynhetz itself cannot use this translator.
    # `ping 64:ff9b::1.1.1.1` from the host fails, and it is not evidence of
    # anything. Test from a pod, which is the only thing that needs it.
    networking.jool = {
      enable = true;
      nat64.default = {
        # The module already defaults pool6 to the well-known prefix. Said
        # here anyway, because the DNS64 below has to write into the same one
        # and a reader should not have to know the default to check that.
        global.pool6 = nat64Prefix;

        # The addresses and ports Jool may masquerade pods behind.
        #
        # There is one public IPv4 on this machine and the host is already
        # using it, so the port range is the whole of the sharing agreement.
        # 61001-65535 sits above the kernel's ephemeral range, which is
        # 32768-60999 here (net.ipv4.ip_local_port_range, read rather than
        # assumed). So Jool can never pick a port the host is about to pick
        # for a connection of its own, and no listener on this host is up
        # there either.
        #
        # ICMP is in the list on purpose: without it `ping` from a pod fails
        # while TCP works, which reads as a routing problem and is not one.
        pool4 =
          map
            (protocol: {
              inherit protocol;
              prefix = "${nodeIPv4}/32";
              "port range" = "61001-65535";
            })
            [
              "TCP"
              "UDP"
              "ICMP"
            ];

        # Nothing here yet. This is where an inbound port-forward goes: a
        # static BIB entry maps one IPv4 port on this host to one IPv6
        # address and port inside the cluster, which is the only way an
        # IPv4-only client reaches an IPv6-only pod. Netfilter cannot DNAT
        # across address families, so this is not a thing a plain iptables
        # rule can do.
        #
        #   bib = [
        #     {
        #       protocol = "TCP";
        #       "ipv4 address" = "${nodeIPv4}#8080";
        #       "ipv6 address" = "2a01:4f9:3071:11d7:b0::5#80";
        #     }
        #   ];
        #
        # No brackets around the IPv6 address: `#` is the port separator, and
        # a bracketed form is rejected with "Cannot parse '[...]' as an IPv6
        # address". Checked with `jool file check`, which parses a config
        # without touching the kernel and needs no root.
        #
        # Three things go with it. The port needs its own pool4 entry, outside
        # the dynamic range above, or Jool has not reserved it. It must be a
        # port nothing on this host already answers on -- 443 is taken by
        # ./openvpn.nix. And the IPv6 side has to be an address that stays
        # put: a pod address is rebuilt with the pod, so aim at a Service with
        # a fixed address out of the pod /80. A ULA ClusterIP is the tempting
        # target and is not a tested one -- whether Jool's reinjected packet
        # meets kube-proxy's DNAT depends on hook ordering nobody here has
        # measured.
        bib = [ ];
      };
    };

    # Load the module from the generation that carries it, not the booted one,
    # but only when that is provably the same kernel.
    #
    # modprobe resolves against /run/booted-system/kernel-modules. A kernel
    # module that arrives with a switch is therefore invisible to it until the
    # generation carrying that module is the one that booted, so NAT64 would be
    # down from the switch until the next reboot:
    #
    #   modprobe: FATAL: Module jool not found in directory
    #     /run/booted-system/kernel-modules/lib/modules/7.2.0
    #
    # -d names a different root, and the just-activated generation has the
    # module. What -d must not do is load a module built for one kernel into
    # another. Two guards, and only the second is sufficient:
    #
    #   the version in the path   -d appends lib/modules/$(uname -r), so a
    #                             generation with a different kernel *version*
    #                             misses the directory entirely and fails. That
    #                             is free, and it is not enough: a nixpkgs bump
    #                             can rebuild 7.2.0 and keep the string.
    #   the kernel store path     two builds of the same version are two store
    #                             paths. Comparing them is exact: equal means
    #                             the running kernel IS the one this generation
    #                             carries, so its modules were built against
    #                             it. Nothing else is.
    #
    # When they differ the script falls back to plain modprobe, which reads the
    # booted tree. That is the honest answer: a genuinely new kernel does need
    # a reboot, and this says so rather than loading something that happens to
    # be lying next to the right name.
    #
    # mkForce because the module states ExecStartPre as a plain value.
    systemd.services."jool-nat64-default".serviceConfig.ExecStartPre = lib.mkForce (
      lib.getExe (
        pkgs.writeShellApplication {
          name = "jool-modprobe";
          runtimeInputs = [
            pkgs.coreutils
            pkgs.kmod
          ];
          text = ''
            booted=$(readlink -f /run/booted-system/kernel)
            current=$(readlink -f /run/current-system/kernel)

            if [ "$booted" = "$current" ]; then
              exec modprobe -d /run/current-system/kernel-modules jool
            fi

            echo "jool: the activated generation carries a different kernel" >&2
            echo "  booted:  $booted" >&2
            echo "  current: $current" >&2
            echo "so its modules were not built for the running kernel." >&2
            echo "Reboot to pick them up. Trying the booted generation." >&2
            exec modprobe jool
          '';
        }
      )
    );

    # ── DNS64: an AAAA for a name that has none ──────────────────────────

    # unbound, and not the CoreDNS already running in the cluster, which has a
    # dns64 plugin of its own. CoreDNS's Corefile is a ConfigMap that kubeadm
    # writes during `kubeadm init`, so configuring it from here means either
    # patching a live object at activation time or forking the addon. Both put
    # cluster state in Nix's hands and lose it on the next `kubeadm reset`.
    #
    # Every pod's resolver path already runs through a file this host owns
    # (/etc/kubernetes/resolv.conf, redefined below), so putting the DNS64
    # behind that file needs nothing from the cluster at all.
    services.unbound = {
      enable = true;
      # Off, or unbound becomes the host's own resolver through resolved. The
      # host is dual-stack and wants ordinary answers; only pods want
      # synthesized ones.
      resolveLocalQueries = false;
      # Nothing validates here, so an anchor would only be a file to maintain.
      # The upstreams below validate on their own behalf.
      enableRootTrustAnchor = false;
      settings = {
        server = {
          # The node address, because that is the address a pod can reach: a
          # pod's route to this host is cni0, and cni0's own address is created
          # by the CNI plugin when the first pod starts, long after unbound.
          interface = [ nodeIP ];
          # unbound would otherwise refuse to start until networkd has put the
          # address on eth0.
          ip-freebind = true;

          # Two layers keep this off the internet, because an open resolver on
          # a public address is an amplifier for somebody else's attack.
          #
          # This one is unbound's: everything is refused but the pods and the
          # host itself. The other is the firewall's -- ./kubernetes/default.nix trusts
          # cni0 and opens no port on eth0, and 53 is not among the ports it
          # opens, so a query from the internet is dropped before unbound sees
          # it. Neither layer is load-bearing on its own.
          #
          # The virtual machine subnet is here for a sharper reason than the
          # pods are. Talos pulls its own installer from ghcr.io, which has no
          # IPv6 address, so a node on that bridge reaches the image it is
          # made of only through this resolver and Jool. A public resolver
          # would answer with nothing it can use.
          # ./kubernetes/vm-network.nix opens 53 on that bridge to match; both
          # are needed, and either one alone fails quietly.
          access-control = [
            "::/0 refuse"
            "0.0.0.0/0 refuse"
            "${podSubnet} allow"
            "${vmSubnet} allow"
            "${nodeIP}/128 allow"
            "::1/128 allow"
          ];

          # The dns64 module runs in front of the iterator and synthesizes only
          # when the real answer comes back with no AAAA. A dual-stack name is
          # returned untouched, which is what keeps this from routing traffic
          # through the translator that never needed to go there.
          module-config = ''"dns64 iterator"'';
          dns64-prefix = nat64Prefix;

          # The upstreams are IPv6, and so is every client.
          do-ip4 = false;
          do-ip6 = true;

          hide-identity = true;
          hide-version = true;
        };

        # Forward rather than recurse. Hetzner's resolvers are one hop away and
        # already cache for this whole rack.
        forward-zone = [
          {
            name = ".";
            forward-addr = upstream;
          }
        ];
      };
    };

    # What every pod gets as its /etc/resolv.conf, and what CoreDNS forwards
    # to. ./kubernetes/node.nix names the Hetzner resolvers here with mkDefault, so
    # that it stands on its own the day this file goes away; a plain definition
    # takes over while this file exists. That is the same split the two files
    # already use for the IPv6 forwarding sysctls.
    #
    # A pod picks this file up when it is created, so CoreDNS keeps the old
    # contents until its pods are replaced. `kubectl -n kube-system rollout
    # restart deployment coredns` is the one thing a rebuild does not do for
    # itself.
    environment.etc."kubernetes/resolv.conf".text = ''
      nameserver ${nodeIP}
    '';
  };
}
