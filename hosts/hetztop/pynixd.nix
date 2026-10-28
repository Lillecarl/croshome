{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:
{
  config = {
    # Disabled 2026-08-23 while python3.15 work happens upstream in the
    # pinned pynixd tree; the pynixd package env fails to build (tornado
    # tests) and takes this whole rebuild down. Restore once the upstream
    # refactor lands:
    #   services.pynixd = {
    #     enable = true;
    #     # The module states no default for `package` -- only `nixosModules.pynixd`
    #     # in pynixd's own flake does, and this imports the module file directly.
    #     package = nixidaePynixd.pynixd.packages.pynixd;
    #     settings = {
    #       log_level = "DEBUG";
    #       plugins = [ "/etc/pynixd/filter.py" ];
    #       gc_local_max_age = 604800;
    #       stores = lib.mkIf false {
    #         pynixd-kube = {
    #           type = "ssh-subprocess";
    #           username = "nix";
    #           host = "pynixd.lillecarl.com";
    #           port = 2222;
    #           client_keys = [ "/root/.ssh/id_ed25519" ];
    #           monitor = false;
    #           priority = 2.0;
    #           gc_enabled = false;
    #         };
    #         nixbuildnet = {
    #           type = "ssh-subprocess";
    #           username = "nix";
    #           host = "eu.nixbuild.net";
    #           client_keys = [ "/root/.ssh/id_ed25519" ];
    #           monitor = false;
    #           priority = 0.5;
    #           gc_enabled = false;
    #         };
    #       };
    #     };
    #   };
  };
}
