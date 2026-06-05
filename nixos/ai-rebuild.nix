{ pkgs, lib, ... }:

let
  ai-nixos-rebuild = pkgs.writeShellApplication {
    name = "ai-nixos-rebuild";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.nixos-rebuild
    ];
    text = ''
      nixos-rebuild switch --sudo \
        --file /home/lillecarl/Code/croshome --attr hetztop
    '';
  };

  ai-nixos-rebuild-pynixd = pkgs.writeShellApplication {
    name = "ai-nixos-rebuild-pynixd";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.nixos-rebuild
    ];
    text = ''
      # NIX_REMOTE=unix:///run/pynixd/pynixd.sock nixos-rebuild switch --sudo \
      #   --file /home/lillecarl/Code/croshome --attr hetztop
      nixos-rebuild switch --sudo \
        --option eval-store unix:///nix/var/nix/daemon-socket/socket --option store unix:///run/pynixd/pynixd.sock \
        --file /home/lillecarl/Code/croshome --attr hetztop
    '';
  };
in
{
  security.wrappers = {
    ai-nixos-rebuild = {
      enable = true;
      capabilities = "";
      group = "root";
      owner = "root";
      permissions = "u+rx,g+x,o+x";
      setuid = true;
      setgid = false;
      source = lib.getExe ai-nixos-rebuild;
    };
    ai-nixos-rebuild-pynixd = {
      enable = true;
      capabilities = "";
      group = "root";
      owner = "root";
      permissions = "u+rx,g+x,o+x";
      setuid = true;
      setgid = false;
      source = lib.getExe ai-nixos-rebuild-pynixd;
    };
  };

  security.sudo.extraRules = [
    {
      users = [ "lillecarl" ];
      commands = [
        {
          command = "/run/wrappers/bin/ai-nixos-rebuild";
          options = [ "NOPASSWD" ];
        }
        {
          command = "/run/wrappers/bin/ai-nixos-rebuild-pynixd";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];
}
