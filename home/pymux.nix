{
  config,
  inputs,
  lib,
  selfStr,
  ...
}:
{
  # pymux, a terminal multiplexer written in Python. It sits next to tmux
  # rather than replacing it: ./tmux.nix stays, and both are installed.
  #
  # The module is a plain path inside the pyterm tree, so this needs no flake
  # output. `package` is left at its default, which builds pymux out of the
  # same tree with this configuration's `pkgs`.
  imports = [ "${inputs.pyterm}/nix/home-manager.nix" ];

  programs.pymux = {
    enable = true;

    # `settings` writes one `set-option` line per entry, and the names are
    # pymux's own. `pymux/pymux/options.py` in the pyterm tree lists them.
    # Nothing here checks a name; pymux reports one it does not know at
    # startup, and names the file and the line that said it.
    #
    # These say the same things ./tmux.nix and ./tmux-linked.conf say, so a
    # session behaves the same way whichever multiplexer started it. What tmux
    # sets and pymux has no option for is left out rather than guessed at.
    settings = {
      base-index = 1;
      # Draw the ":" command line as a box in the middle of the screen instead
      # of a bar along the bottom. pymux defaults it off, so this states it.
      command-palette = true;
      # `keyMode = "vi"` in ./tmux.nix sets both of these. pymux keeps them
      # apart, so both are stated.
      mode-keys = "vi";
      status-keys = "vi";
      history-limit = 50000;
      # tmux draws this at the top of a pane. pymux has one place for it, so
      # the option is only on or off.
      pane-border-status = true;
      extended-keys = "on";
      default-shell = lib.getExe config.programs.fish.package;
    };

    # The bindings live in a file this reads at startup, not here. That file is
    # an out-of-store symlink, so a binding can be tried without a rebuild --
    # the same arrangement as ./tmux-linked.conf.
    #
    # An absolute path, and not `~`. `source-file` does expand `~`, but the
    # generated file already knows where XDG put it.
    extraConfig = ''
      source-file ${config.xdg.configHome}/pymux/linked.conf
    '';
  };

  xdg.configFile."pymux/linked.conf".source =
    config.lib.file.mkOutOfStoreSymlink "${selfStr}/home/pymux-linked.conf";
}
