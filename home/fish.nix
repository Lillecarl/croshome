{ config, selfStr, ... }:
let
  themeName = "Catppuccin Mocha";
  inherit (config.catppuccin) sources;
in
{
  config = {
    catppuccin.fish.enable = false;
    programs.fish = {
      enable = true;
      shellInit = # fish
        ''
          # fish_config theme choose "${themeName}" --color-theme=dark

          # Homebrew's installer only teaches sh-compatible shells, and
          # fish never reads .zprofile, so set its environment here.
          # Guarded by path: only macOS carries /opt/homebrew.
          if test -x /opt/homebrew/bin/brew
            eval (/opt/homebrew/bin/brew shellenv)
          end
        '';
    };
    xdg.configFile."fish/functions".source =
      config.lib.file.mkOutOfStoreSymlink "${selfStr}/home/fish/functions";
    xdg.configFile."fish/conf.d".source =
      config.lib.file.mkOutOfStoreSymlink "${selfStr}/home/fish/conf.d";
    programs.zoxide = {
      enable = true;
      enableFishIntegration = true;
    };
    programs.starship = {
      enable = true;
      enableFishIntegration = true;
    };
    # xdg.configFile."fish/themes/${themeName}.theme".source = "${sources.fish}/${themeName}.theme";
  };
}
