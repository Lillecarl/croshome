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
          fish_config theme choose "${themeName}" --color-theme=dark
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
    xdg.configFile."fish/themes/${themeName}.theme".source = "${sources.fish}/${themeName}.theme";
  };
}
