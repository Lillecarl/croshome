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

    // qutebrowser's keys. Glide has no API to focus the address bar, so
    // `o` and `O` press Firefox's own shortcuts.
    glide.keymaps.set("normal", "o", () => glide.keys.send("<D-l>", { skip_mappings: true }), {
      description: "Open an address in this tab",
    });
    glide.keymaps.set("normal", "O", () => glide.keys.send("<D-t>", { skip_mappings: true }), {
      description: "Open an address in a new tab",
    });
    glide.keymaps.set("normal", "J", "tab_next");
    glide.keymaps.set("normal", "K", "tab_prev");
    glide.keymaps.set("normal", "H", "back");
    glide.keymaps.set("normal", "L", "forward");

    // Firefox focuses the address bar on every switch to an empty New Tab,
    // which leaves Glide in insert mode. Keep it on a tab just opened, so
    // `O` and Cmd-T still land in the address bar. A config reload clears
    // these listeners, so they never pile up.
    const opened = new Set<number>();
    browser.tabs.onCreated.addListener((tab) => {
      if (tab.id !== undefined) opened.add(tab.id);
    });
    browser.tabs.onActivated.addListener(async ({ tabId }) => {
      if (opened.delete(tabId)) return;
      const tab = await browser.tabs.get(tabId);
      if (tab.url === "about:newtab" || tab.url === "about:home") await glide.excmds.execute("blur");
    });
  '';
}
