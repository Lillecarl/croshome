{ ... }:
{
  # The kitty.app bundle is installed system-wide in
  # ../../hosts/macbook/default.nix, because nix-darwin has to rsync it into
  # /Applications/Nix Apps for Spotlight and Launchpad to find it. So this
  # manages ~/.config/kitty only.
  #
  # Linux uses foot instead, which is a Wayland terminal and has no macOS
  # build; the two are configured separately rather than through one option
  # set, because almost nothing about them lines up.
  programs.kitty = {
    enable = true;
    package = null;
    settings = {
      scrollback_lines = 10000;
      # macOS has no global way to drop window chrome; each app has to offer it.
      # titlebar-and-corners also squares off the rounded corners, which tile
      # better than the default ones.
      hide_window_decorations = "titlebar-and-corners";

      # `kitty @ ...` from a shell inside kitty talks over the tty escape
      # channel, so this alone is enough for self-control. It does mean any
      # program running in the terminal -- including one on the far end of an
      # ssh session -- can drive the whole instance.
      allow_remote_control = "yes";
    };
  };
}
