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

    // Run `fn` in the active tab's page, or answer `fallback` where Glide
    // may not: Firefox's own pages, such as New Tab, answer "missing host
    // permission for the tab".
    const in_page = async <T,>(fn: () => T, fallback: T): Promise<T> => {
      try {
        return await glide.content.execute(fn, { tab_id: await glide.tabs.active() });
      } catch {
        return fallback;
      }
    };

    // Whether the cursor is in a field, where Glide's normal mode edits text.
    const editing = () =>
      in_page(() => {
        const at = document.activeElement;
        return !!at && (at.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(at.tagName));
      }, false);

    // Vimium's x and X close and reopen a tab; in a field they still
    // delete a character, as Glide's do. Closing the last tab leaves a
    // New Tab rather than closing the window, as in qutebrowser.
    glide.prefs.set("browser.tabs.closeWindowWithLastTab", false);
    glide.keymaps.set("normal", "x", async () => {
      await glide.excmds.execute((await editing()) ? "motion x" : "tab_close");
    }, { description: "Delete a character in a field, else close the tab" });
    glide.keymaps.set("normal", "X", async () => {
      await glide.excmds.execute((await editing()) ? "motion X" : "tab_reopen");
    }, { description: "Delete the character before in a field, else reopen the last closed tab" });

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
      const page = await in_page(
        () => ({ focused: document.hasFocus(), clicked: navigator.userActivation.isActive }),
        null,
      );
      // Firefox's own page, or the address bar has the focus, not the page.
      if (!page || !page.focused) return;
      if (page.clicked && Date.now() - switched > 1000) return;
      await glide.excmds.execute("blur");
      await glide.excmds.execute("mode_change normal");
    });

    // `i` inserts where the cursor is, not one character left as Glide's
    // does; `a` one character right. Both go back into the last field
    // when none has the focus, such as after the rule above took it away.
    const insert = async (move: "right" | null) => {
      if (!(await editing())) await glide.excmds.execute("focusinput last");
      else if (move) await glide.excmds.execute(`caret_move ''${move}`);
      await glide.excmds.execute("mode_change insert");
    };
    glide.keymaps.set("normal", "i", () => insert(null), { description: "Insert where the cursor is" });
    glide.keymaps.set("normal", "a", () => insert("right"), {
      description: "Insert after the character under the cursor",
    });
  '';
}
