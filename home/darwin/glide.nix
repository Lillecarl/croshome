{
  config,
  inputs,
  pkgs,
  ...
}:
let
  # The socket is written in: a Glide started from the Dock does not see
  # the shell's XDG_STATE_HOME. pymux-mcp looks for it at the same path.
  bridge = pkgs.runCommand "glide-pymux-bridge.ts" { } ''
    ${pkgs.python3.interpreter} ${inputs.pyterm.outPath}/pymux/pymux-mcp/pymux_mcp/glidebridge.py \
      --off --socket ${config.xdg.stateHome}/pymux/glide.sock > $out
  '';
in
{
  # Glide is the cask in hosts/macbook/brew.nix; this is its config.
  # A config file runs as a script, not a module: no top-level await.
  xdg.configFile."glide/glide.ts".text = ''
    // pymux-mcp's bridge, closed until `:pymux_bridge on`.
    glide.unstable.include("${bridge}");

    // Firefox's own vertical tabs, in the sidebar.
    glide.prefs.set("sidebar.revamp", true);
    glide.prefs.set("sidebar.verticalTabs", true);
  '';
}
