{ ... }:
{
  # Tiling removes every cue macOS uses for focus: no overlap, no shadow, and
  # with hide_window_decorations no greyed-out title bar either. JankyBorders
  # draws an overlay window tracking each window's frame and colours the
  # focused one differently, which puts that cue back.
  #
  # It only reads the window list and adds overlays, so unlike yabai's
  # scripting addition it needs no SIP changes -- the same reason AeroSpace is
  # usable in the first place.
  services.jankyborders = {
    enable = true;

    # kitty is the only window that ends up square, since titlebar-and-corners
    # squares it off; everything else macOS draws keeps its rounded corners, so
    # this has to follow the majority.
    style = "round";
    # Retina-resolution borders; the panel is one.
    hidpi = true;
    # Only the part outside the frame is visible at order = "below" (default),
    # so this is roughly how much protrudes on each side. Inner gaps are sized
    # to 2*width plus a little, otherwise two neighbours' borders meet in the
    # middle and read as one thick divider.
    width = 6.0;

    # catppuccin-nix has no jankyborders port, so the mocha palette is spelled
    # out: mauve (the configured accent) for focus, surface1 for the rest.
    # 0xAARRGGBB -- alpha first.
    active_color = "0xffcba6f7";
    inactive_color = "0xff45475a";
  };
}
