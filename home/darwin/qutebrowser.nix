{ inputs, pkgs, ... }:
let
  # The lines that load pymux-mcp's bridge and register `:pymux-bridge`,
  # from the same pyterm as the pymux-mcp that talks to it. `--off`: the
  # socket opens only when `:pymux-bridge on` is typed.
  bridge = pkgs.runCommand "qutebrowser-pymux-bridge.py" { } ''
    ${pkgs.python3.interpreter} ${inputs.pyterm.outPath}/pymux/pymux-mcp/pymux_mcp/qutebridge.py --off > $out
  '';
in
{
  # On trial as the main browser. The package comes from our fork, through
  # the overlay. Its cask is disabled: it fails Gatekeeper.
  programs.qutebrowser = {
    enable = true;
    # `:set` writes autoconfig.yml; load it, so a setting tried at runtime
    # survives a restart until it moves here.
    loadAutoconfig = true;
    settings = {
      # Qt on macOS lays text out at 72 logical DPI, so the 10pt default
      # draws 10 px. 14pt chosen by eye on the Dell U3421WE: 13pt read too
      # small, 16pt too big.
      fonts.default_size = "14pt";
      tabs.position = "left";
    };
    extraConfig = ''
      config.source("${bridge}")
    '';
  };
}
