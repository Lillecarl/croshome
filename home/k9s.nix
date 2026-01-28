{
  config,
  lib,
  selfStr,
  ...
}:
{
  config = {
    xdg.configFile."k9s/config.yaml".source = lib.mkForce (
      config.lib.file.mkOutOfStoreSymlink "${selfStr}/home/k9s/config.yaml"
    );
    xdg.configFile."k9s/plugins.yaml".source =
      config.lib.file.mkOutOfStoreSymlink "${selfStr}/home/k9s/plugins.yaml";
    xdg.configFile."k9s/views.yaml".source =
      config.lib.file.mkOutOfStoreSymlink "${selfStr}/home/k9s/views.yaml";
    programs.k9s = {
      enable = true;
    };
  };
}
