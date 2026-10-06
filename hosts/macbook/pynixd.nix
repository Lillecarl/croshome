{
  config,
  pkgs,
  inputs,
  ...
}:
let
  vz = config.nix.linux-vz-builder;
in
{
  config = {
    # The module states no default for `package` -- only `darwinModules.pynixd`
    # in pynixd's own flake does, and this imports the module file directly.
    # Same reasoning as hosts/hetztop/pynixd.nix.
    services.pynixd = {
      enable = true;
      package = (import inputs.nixidae-pynixd { inherit pkgs; }).pynixd.package;
      settings = {
        log_level = "INFO";

        # Reverse initiator: register this machine as a roaming builder
        # with dynhetz. STAGED, not enabled: it needs a builder keypair
        # first. Generate it here, on this machine, so the private key
        # never travels: `ssh-keygen -t ed25519 -f /etc/nix/pynixd-reverse
        # -N ""`, then hand the .pub to dynhetz's
        # /etc/pynixd/builders/macbook.pub and uncomment. Reconnects with
        # backoff whenever the tunnel is down, so nothing here depends on
        # dynhetz being reachable at boot.
        #
        # reverse_initiator = {
        #   enabled = true;
        #   acceptor_host = "10.100.0.1"; # dynhetz over wg-dynhetz.
        #   acceptor_port = 2235;
        #   store_id = "macbook";
        #   systems = [ "aarch64-darwin" ];
        #   server_host_key_paths = [ "/etc/nix/pynixd-reverse" ];
        # };

        stores.vz-builder = {
          # `ssh-subprocess` runs `nix-daemon --stdio` on the far side, which is
          # what `nix.buildMachines` already does with `protocol = "ssh-ng"`.
          # The two reach the same guest by the same route and do not conflict:
          # each opens its own connection.
          type = "ssh-subprocess";

          # Every field here restates something ./vz-builder already knows,
          # because pynixd speaks SSH through asyncssh and not through the
          # `ssh` binary. /etc/ssh/ssh_config.d/101-vz-builder.conf is therefore
          # invisible to it, and the `vz-builder` host alias does not resolve.
          # `port` and the key path are read from the module rather than typed
          # again, so they cannot drift from it.
          host = "127.0.0.1";
          port = vz.port;
          username = "builder";
          client_keys = [ "/etc/nix/builder_ed25519" ];

          # Probed, and not stated. `systems` and `system_features` are left
          # unset on purpose: pynixd asks the guest what it is, and the guest
          # answers from its own configuration. A list written here is a second
          # copy of that answer, and a copy goes stale -- Rosetta, the feature
          # set, and the systems the guest accepts are all decided in
          # ./vz-builder, not here.
          #
          # The cost is that probing connects, and connecting starts the VM.
          # One boot to learn what the builder can do is a fair price for an
          # answer that cannot go stale, now that pynixd lets the connection go
          # again -- see `persistent_connection` below.

          # The option that makes this builder work at all, and the default is
          # the other way. pynixd normally holds one SSH connection per store
          # for its whole life, on purpose: the state of that connection is how
          # it knows whether a remote builder is up, and the reconnect loop,
          # the backoff and the circuit breaker all read it.
          #
          # This builder is the case that trade does not fit. Connecting to the
          # loopback port is what starts the VM, and a connection that never
          # closes is a VM that never stops -- an 8 GiB guest resident for as
          # long as pynixd runs, on a machine designed to boot it per build.
          # Added upstream for this machine as Lillecarl/nanopynix#164.
          #
          # What it costs, and it is a real cost: with nothing held open there
          # is nothing to read health from, so pynixd learns this builder is
          # down by failing to reach it rather than by noticing beforehand.
          # For a VM on loopback that is the right way round -- it is only ever
          # "down" in the sense of "not booted yet", which is not a fault.
          persistent_connection = false;

          # A poller, and it polls over the same connection. Left on it would
          # hold the VM awake by itself and undo the line above. pynixd warns
          # about exactly this combination.
          monitor = false;

          # Also a wake-up, and a pointless one: /nix/.rw-store is an ephemeral
          # disk image that the guest reformats on every boot. There is nothing
          # for a garbage collector to keep.
          gc_enabled = false;

          # `priority` is left at its default. It would arbitrate between two
          # stores that can both take a build, and there is no second Linux
          # store here -- the local one is aarch64-darwin. Worth knowing before
          # setting it: the field runs in opposite directions. Scheduling sorts
          # by score descending, so higher wins (`allocator.py`), and
          # substitution takes `min(key=priority)`, so lower wins
          # (`substitution_queue.py`).
        };
      };
    };
  };
}
