{
  config,
  pkgs,
  lib,
  ...
}:
{
  config = {
    environment.etc."pynixd/filter.py".source =
      "${config.services.pynixd.package.src}/pynixd/filters/scheduler_focus.py";
    services.pynixd = {
      enable = true;
      settings = {
        log_level = "DEBUG";
        plugins = [ "/etc/pynixd/filter.py" ];
        gc_local_max_age = 604800;
        stores = lib.mkIf false {
          pynixd-kube = {
            type = "ssh-subprocess";
            username = "nix";
            host = "pynixd.lillecarl.com";
            port = 2222;
            client_keys = [ "/root/.ssh/id_ed25519" ];
            monitor = false;
            priority = 2.0;
            gc_enabled = false;
          };
          nixbuildnet = {
            type = "ssh-subprocess";
            username = "nix";
            host = "eu.nixbuild.net";
            client_keys = [ "/root/.ssh/id_ed25519" ];
            monitor = false;
            priority = 0.5;
            gc_enabled = false;
          };
        };
      };
    };
  };
}
