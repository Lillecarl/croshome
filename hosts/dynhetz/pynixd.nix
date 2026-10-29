{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:
let
  httpCache = url: {
    type = "http-binary-cache";
    inherit url;
  };

  # nix-community's aarch64 builders, for capability only: `last_resort`
  # sends them a derivation only when no other healthy store supports its
  # system and features, never to shed load. Shared machines, so no probe
  # builds, no monitor agent, and no connection held while idle. Every
  # trusted user there can write to that store, so an output built there is
  # only as trustworthy as they are. x86_64 stays off them; that would be
  # offloading. The login is
  # the user's key, the one nix-community registered; pynixd runs as root
  # and reads it.
  nixCommunity =
    {
      host,
      system,
      features,
    }:
    {
      type = "ssh-subprocess";
      inherit host;
      username = "lillecarl";
      known_hosts = "/etc/pynixd/builders/nix-community.known_hosts";
      client_keys = [ "/home/lillecarl/.ssh/id_ed25519" ];
      last_resort = true;
      monitor = false;
      probe = false;
      persistent_connection = false;
      feature_matrix.${system} = features;
    };
in
{
  # Host keys as published at https://nix-community.org/community-builders/,
  # matching ssh-keyscan on 2026-10-22.
  environment.etc."pynixd/builders/nix-community.known_hosts".text = ''
    aarch64-build-box.nix-community.org ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG9uyfhyli+BRtk64y+niqtb+sKquRGGZ87f4YRc8EE1
    darwin-build-box.nix-community.org ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKMHhlcn7fUpUuiOFeIhDqBzBNFsbNqq+NpzuGX3e6zv
  '';

  # The MacBook builder's public key, pinned by reverse_acceptor below.
  # Public, so it commits like ../../lillecarl.pub itself: it is that same
  # key, shared with this machine's user. A missing file fails the daemon
  # at startup, never silently.
  environment.etc."pynixd/builders/macbook.pub".source = ../../lillecarl.pub;
  # SSH host keys of the SG1 nodes (solid-kubernetes environments/sg1/nixos,
  # modules/common/lab.nix). n1-n3 register as x86_64-linux builders, the
  # GX10s as aarch64-linux, until the cluster goes to production.
  environment.etc."pynixd/builders/sg1.pub".source = ./sg1-builders.pub;

  # The acceptor below faces the internet. Same shape as services that
  # open their own port (../ttyd.nix): the rule lives with the service.
  networking.firewall.allowedTCPPorts = [ 2235 ];

  # Nix 2.35 names the socket-activated descriptor `nix-daemon.socket` in
  # LISTEN_FDNAMES, and the upstream socket unit pynixd listens behind relies
  # on that name. Under 2.34 the socket activates on nothing and every client
  # hangs, so `replace` needs this version.
  nix.package = pkgs.nixVersions.latest;

  services.pynixd = {
    enable = true;
    # `replace`: pynixd takes /nix/var/nix/daemon-socket/socket and nix-daemon
    # moves behind it as nix-daemon-upstream.socket/.service, so every client
    # reaches pynixd. nix-daemon still runs the builds; pynixd only proxies.
    # The module masks Nix's own two units, so switch-to-configuration moves
    # the sockets in both directions with no hand step.
    #
    # If pynixd misbehaves, the real daemon is still on the upstream socket:
    #   nix --store unix:///nix/var/nix/daemon-socket/upstream ...
    mode = "replace";
    settings = {
      log_level = "INFO";
      plugins = [ "/etc/pynixd/filter.py" ];
      # Evidence phase for age-based GC: the hourly loop runs, but deletes
      # are refused (`GCNotPermittedError`) until the liveness mirror shows
      # sustained zero-divergence. The refused passes log as
      # `gc_execute_not_permitted`, which is the interlock proving itself,
      # and the differential logs beside them as `gc_liveness_agreement`
      # or `gc_liveness_divergence`.
      gc_enabled = true;
      # Seconds between liveness differential checks. Each wake refreshes
      # the mirror -- cheap, no locks -- and at most one trace per interval
      # asks Nix what is alive, which traces the roots under the garbage
      # collector lock like a dry-run. A flapping link refreshes without
      # tracing, so generation churn cannot hold the lock continuously.
      # The traces buy agreement points for the cutover; the mirror they
      # compare against is what OP101 plans from.
      gc_liveness_interval = 3600;
      # Trigger: usage fraction that starts a bounded GC drive between
      # schedules. 0.75 fires past three quarters full; the drive runs
      # bounded passes back to back down to the store's target, and that
      # gap is the hysteresis. Shares one gc_cooldown window (900s) with
      # scheduled passes, so a hovering disk fires at most once per window.
      gc_high_watermark = 0.75;
      # Each placement decision, with every score term and the expected
      # seconds per store, into the store database: the evidence for why a
      # build went where it went (nixidae/nixidae#1070). Rows older than a
      # week go in chunks.
      placement_trace.enabled = true;
      # Keep short builds here. Re-scored over 352 traced decisions
      # (nixidae/nixidae#1125), pricing each store's whole expected time at
      # 50 points a second, and counting the CPU points in full only from a
      # 5 s build, keeps 81-85 % of builds local and halves the expected
      # time lost against the fastest store. A 200 ms build takes 600 ms on
      # sg1. A build costs one core's share, so a store fills at its core
      # count and not after one build per pass, and local wins a tie.
      ranking = {
        time_penalty_per_second = 50;
        cpu_reference_seconds = 5;
        per_core_load = true;
        local_wins_ties = true;
      };
      # A store gets a build scheduled to it only when it has a feature
      # matrix. With none, pynixd probes the daemon with test builds at
      # startup and, until that finishes, refuses every build with "no
      # feature_matrix (not probed)". On a busy store the probe also overruns
      # systemd's start timeout, so pynixd never reaches READY at all.
      # Declaring the matrix gives the local store one outright: scheduled,
      # and no probe. Features mirror nix.settings.system-features on this
      # host (./default.nix).
      stores.local = {
        systems = [ "x86_64-linux" ];
        system_features = [
          "nixos-test"
          "benchmark"
          "big-parallel"
          "kvm"
          "uid-range"
          # Mirrors nix.settings.system-features: pydd's planner builds
          # need the daemon socket, and without this the scheduler refuses
          # them with "no compatible store".
          "recursive-nix"
        ];
        # Dead and unreferenced for a day may be collected. A week planned
        # nothing on a three-day-old tracker, which is the safe direction
        # but also the useless one; a day matches what the access table
        # actually remembers. Liveness still beats age: rooted paths stay
        # whatever their timestamp says.
        gc_max_age = 86400;
        # Permitted by operator decision 2026-10-05 after dry-run plans
        # showed zero overlap with the running system: planning stays free,
        # and EXECUTE now deletes what the plan names, vetoed roots aside.
        # Set back to false to refuse deletes again; nothing else changes.
        gc_allow_execute = true;
        # Floor: collection passes stop once freed bytes project usage
        # under this fraction. 0.70 ends the relief the 0.75 watermark
        # starts; without it a triggered pass is unbounded.
        gc_target_usage = 0.7;
      };

      # The upstream caches live here, not in nix.conf: Nix asks only
      # pynixd's cache (./default.nix), which races these at once. With
      # them in nix.conf too, Nix asked each in turn after pynixd missed,
      # 1.2 s before every new local build (nixidae/nixidae#1125).
      stores.cache-nixos-org = httpCache "https://cache.nixos.org";
      stores.lillecarl-cachix = httpCache "https://lillecarl.cachix.org";
      stores.nixkube-cachix = httpCache "https://nixkube.cachix.org";
      stores.cyberus-linux = httpCache "https://cache.cyberus-linux.com";
      stores.kubernetes4nix-cachix = httpCache "https://kubernetes4nix.cachix.org";

      stores.nix-community-aarch64-linux = nixCommunity {
        host = "aarch64-build-box.nix-community.org";
        system = "aarch64-linux";
        features = [
          "kvm"
          "nixos-test"
          "big-parallel"
          "benchmark"
        ];
      };
      stores.nix-community-aarch64-darwin = nixCommunity {
        host = "darwin-build-box.nix-community.org";
        system = "aarch64-darwin";
        features = [
          "apple-virt"
          "nixos-test"
          "big-parallel"
          "benchmark"
        ];
      };

      # Reverse builder acceptor, for the MacBook as a roaming
      # aarch64-darwin builder. Public port, pinned builders: anyone may
      # connect, but only the pinned MacBook key registers -- a rogue key
      # registers nothing. Pre-auth exposure is noise and DoS, not trust.
      # The MacBook side (reverse_initiator, hosts/macbook/pynixd.nix)
      # dials this port and registers itself when online; the scheduler
      # picks it up dynamically.
      reverse_acceptor = {
        enabled = true;
        # Default host (every interface, v4 and v6) on purpose.
        port = 2235;
        authorized_builder_keys = [
          "/etc/pynixd/builders/macbook.pub"
          "/etc/pynixd/builders/sg1.pub"
        ];
      };

      # HTTP binary cache for this machine's own daemons, first in their
      # substituter list (../default.nix). Localhost only: it serves
      # whatever the local store holds to anyone who asks, and only this
      # machine should ask. Misses race every upstream at once and
      # redirect by priority, so serial per-path Nix queries go parallel
      # here instead.
      http_host = "127.0.0.1";
      http_port = 8080;
    };
  };
}
