{
  config,
  pkgs,
  lib,
  osConfig,
  inputs,
  ...
}:
{
  imports = [ inputs.catppuccin.homeModules.catppuccin ];
  config = {
    home.stateVersion = osConfig.system.stateVersion;
    home.packages = with pkgs; [
      stern
    ];
    programs.kubeswitch = {
      enable = true;
      enableFishIntegration = true;
    };
    programs.kubecolor.enable = true;
    programs.k9s.enable = true;
    programs.fish.enable = true;
    programs.lsd.enable = true;
    programs.ripgrep.enable = true;
    programs.fd.enable = true;
    programs.jq.enable = true;
    programs.tmux = {
      enable = true;
      shell = lib.getExe config.programs.fish.package;
      aggressiveResize = true;
      escapeTime = 0;
      sensibleOnTop = true;
      baseIndex = 1;
      keyMode = "vi";
      clock24 = true;
      extraConfig = # tmux
        ''
          bind -n C-S-h select-pane -L
          bind -n C-S-j select-pane -D
          bind -n C-S-k select-pane -U
          bind -n C-S-l select-pane -R
          bind -n M-h select-pane -L
          bind -n M-j select-pane -D
          bind -n M-k select-pane -U
          bind -n M-l select-pane -R
          # Use the modern terminfo for tmux
          set -g default-terminal "tmux-256color"

          # Tell tmux that 'foot' supports RGB (True Color)
          # The leading comma is important
          set-option -sa terminal-features ',foot:RGB'
        '';
    };
    programs.jujutsu = {
      enable = true;
      settings = {
        user.name = "lillecarl";
        user.email = "git@lillecarl.com";
      };
    };
    programs.git = {
      enable = true;
      settings = {
        user.name = "lillecarl";
        user.email = "git@lillecarl.com";
      };
    };
    programs.jjui = {
      enable = true;
      settings = { };
    };
    programs.helix.enable = true;
    programs.direnv.enable = true;
  };
}
