{
  pkgs,
  ...
}:
{
  imports = [
    ./emacs.nix
    ./fonts.nix
    ./foot.nix
  ];

  # Only what genuinely cannot work on macOS belongs here, and "genuinely" is
  # decided by running the binary on darwin -- not by meta.platforms, not by
  # whether the build goes green. wireguard-tools, sbomnix and every agent CLI
  # passed that test, so they are in ../packages.nix and ../agents.nix. What is
  # left below is a kernel API and two Wayland tools.
  home.packages = with pkgs; [
    # inotify is a Linux kernel API with no macOS equivalent in this package.
    inotify-tools
    # Wayland: the protocol proxy and the clipboard tool. The MacBook reaches
    # Linux applications through Cocoa-Way, which brings its own waypipe, and
    # its clipboard is pbcopy -- see home/fish/functions/copy.fish.
    waypipe
    wl-clipboard
  ];
}
