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
    let switched = 0;
    browser.tabs.onCreated.addListener((tab) => {
      if (tab.id !== undefined) opened.add(tab.id);
    });
    browser.tabs.onActivated.addListener(async ({ tabId }) => {
      switched = Date.now();
      if (opened.delete(tabId)) return;
      const tab = await browser.tabs.get(tabId);
      if (tab.url === "about:newtab" || tab.url === "about:home") await glide.excmds.execute("blur");
    });

    // A page cannot put Glide in insert mode by itself: not by focusing a
    // field on load (Google does), nor by Firefox restoring a field's
    // focus on a tab switch. Insert mode stays when it follows a key
    // pressed after the switch, or a click in the page.
    let pressed = 0;
    glide.autocmds.create("KeyStateChanged", () => {
      pressed = Date.now();
    });
    glide.autocmds.create("ModeChanged", "normal:insert", async () => {
      if (pressed > switched && Date.now() - pressed < 1000) return;
      const tab_id = await glide.tabs.active();
      const page = await glide.content.execute(
        () => ({ focused: document.hasFocus(), clicked: navigator.userActivation.isActive }),
        { tab_id },
      );
      // The address bar has the focus, not the page.
      if (!page.focused) return;
      if (page.clicked && Date.now() - switched > 1000) return;
      await glide.excmds.execute("blur");
      await glide.excmds.execute("mode_change normal");
    });

    // `i` inserts where the cursor is, not one character left as Glide's
    // does; `a` one character right. Both go back into the last field
    // when none has the focus, such as after the rule above took it away.
    const insert = async (move: "right" | null) => {
      const tab_id = await glide.tabs.active();
      const editing = await glide.content.execute(() => {
        const at = document.activeElement;
        return !!at && (at.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(at.tagName));
      }, { tab_id });
      if (!editing) await glide.excmds.execute("focusinput last");
      else if (move) await glide.excmds.execute(`caret_move ''${move}`);
      await glide.excmds.execute("mode_change insert");
    };
    glide.keymaps.set("normal", "i", () => insert(null), { description: "Insert where the cursor is" });
    glide.keymaps.set("normal", "a", () => insert("right"), {
      description: "Insert after the character under the cursor",
    });
  '';
}
