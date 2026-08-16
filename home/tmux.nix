{
  config,
  lib,
  selfStr,
  ...
}:
{
  programs.tmux = {
    enable = true;
    shell = lib.getExe config.programs.fish.package;
    aggressiveResize = true;
    escapeTime = 0;
    sensibleOnTop = true;
    baseIndex = 1;
    keyMode = "vi";
    clock24 = true;
    terminal = "tmux-256color";
    tmuxp.enable = true;
    # The rest is an out-of-store symlink, so a binding can be tried without a
    # rebuild.
    #
    # ChromeOS used to state its own bindings inline instead of reading this
    # file, and they were not the same: there M-h/j/k/l selected the pane to
    # the left/below/above/right. Here M-h and M-l cycle panes, and M-j and
    # M-k move between windows. ChromeOS now follows the shared file.
    extraConfig = # tmux
      ''
        source-file ~/.config/tmux/linked.conf
      '';
  };

  xdg.configFile."tmux/linked.conf".source =
    config.lib.file.mkOutOfStoreSymlink "${selfStr}/home/tmux-linked.conf";
}
