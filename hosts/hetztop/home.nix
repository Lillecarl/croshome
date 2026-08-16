{
  config,
  osConfig,
  selfStr,
  ...
}:
{
  imports = [ ../../home ];

  # There is a NixOS underneath this one, so take its stateVersion rather than
  # keep a second copy that can drift from it.
  home.stateVersion = osConfig.system.stateVersion;

  # ~/.local/bin. Only this host has the scripts in it on its PATH; the MacBook
  # and ChromeOS have no use for k9s-ssh-node or claudenix.
  home.file.".local/bin".source = config.lib.file.mkOutOfStoreSymlink "${selfStr}/home/localbin";
  home.sessionPath = [
    "${config.home.homeDirectory}/.local/bin"
  ];
}
