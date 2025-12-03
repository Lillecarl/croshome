{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:
{
  imports = [
    inputs.catppuccin.homeModules.catppuccin
  ];
  config = {
    catppuccin = {
      enable = true;
      # disable catppuccin modules here
    };
    fonts.fontconfig = {
      enable = true;
      defaultFonts = {
        monospace = [ "Hack" ];
        emoji = [ "Hack" ];
      };
    };
    programs.jq.enable = true;
    programs.ripgrep.enable = true;
    programs.fd.enable = true;
    programs.lsd = {
      enable = true;
      enableFishIntegration = true;
    };
    programs.foot = {
      enable = true;
      settings = {
        main = {
          shell = lib.getExe config.programs.fish.package;
        };
        key-bindings =
          let
            # Bind everything with and without Mod2 (numlock) since it's locked on ChromeOS for some reason
            csMod =
              keys:
              lib.pipe keys [
                lib.toList
                (lib.map (key: "Control+Shift+${key} Control+Shift+Mod2+${key}"))
                (lib.concatStringsSep " ")
              ];
          in
          {
            clipboard-copy = csMod "c";
            clipboard-paste = csMod "v";
            font-decrease = csMod "minus";
            font-increase = csMod "equal";
            font-reset = csMod "0";
            spawn-terminal = csMod "n";
          };
      };
    };
    programs.home-manager.enable = true;
    programs.htop.enable = true;
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
    programs.kitty = {
      enable = true;
      settings = {
        shell = lib.getExe config.programs.fish.package;
        editor = lib.getExe config.programs.helix.package;
      };
    };
    programs.fish.enable = true;
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
    home = {
      username = "lillecarl";
      homeDirectory = "/home/lillecarl";
      shell.enableFishIntegration = true;
      stateVersion = "25.11";
      packages = with pkgs; [
        wl-clipboard
        nixd
        nixfmt
        nerd-fonts.hack
        fish-lsp
        kubectl
      ];
      sessionVariables = {
        EDITOR = lib.getExe config.programs.helix.package;
      };
    };
    targets.genericLinux.enable = true;
  };
}
