// Bootstrap domicile shell: windows side by side, kitty at start and on
// Meta+Return. Stands in until the Svelte shell can.
export const Shell = (root, domicile) => {
  const main = document.createElement("main");
  main.style.cssText =
    "display: flex; gap: 8px; height: 100vh; padding: 8px; box-sizing: border-box; background: #1e1e2e";
  root.append(main);
  const shown = new Map();

  const draw = () => {
    // Menus and tooltips have a parent; they are not tiled.
    const windows = (domicile.windows.list ?? []).filter(
      (window) => window.parent === undefined,
    );
    for (const [appId, app] of shown) {
      if (!windows.some((window) => window.appId === appId)) {
        app.remove();
        shown.delete(appId);
      }
    }
    for (const { appId } of windows) {
      let app = shown.get(appId);
      if (app === undefined) {
        app = document.createElement("app");
        app.setAttribute("app-id", appId);
        app.style.cssText = "border-radius: 8px; flex: 1";
        main.append(app);
        shown.set(appId, app);
      }
      app.style.outline =
        appId === domicile.windows.focused ? "2px solid #74c7ec" : "none";
    }
  };

  draw();
  domicile.windows.on("change", draw);
  domicile.windows.on("focuschange", draw);

  const terminal = () => domicile.processes.launch(["kitty"]);
  // SIGTERM ends domicile cleanly. Its control socket is
  // domicile-ipc.<launcher pid>.sock, and every app it starts has it.
  const quit = () =>
    domicile.processes.launch([
      "sh",
      "-c",
      'p=${DOMICILE_SOCK##*/domicile-ipc.}; kill -TERM "${p%.sock}"',
    ]);
  domicile.keyboard.grab("Meta+Return");
  domicile.keyboard.grab("Meta+Shift+E");
  domicile.keyboard.on("shortcut", ({ chord }) => {
    switch (chord) {
      case "Meta+Return":
        terminal();
        break;
      case "Meta+Shift+E":
        quit();
        break;
    }
  });
  terminal();
};
