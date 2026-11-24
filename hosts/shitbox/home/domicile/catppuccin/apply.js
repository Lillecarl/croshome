// Runs before each style's own file, which calls `catppuccin` with its
// sections: a page has one if any of its rules matches, as @-moz-document.
globalThis.catppuccin = (name, sections) => {
  const done = (globalThis.catppuccinDone ??= new Set());
  // A style whose rules need two content scripts may run twice.
  if (done.has(name)) {
    return;
  }
  done.add(name);

  const { href, hostname } = location;
  const matches = ([kind, value]) => {
    switch (kind) {
      case "domain":
        return hostname === value || hostname.endsWith(`.${value}`);
      case "url-prefix":
        return href.startsWith(value);
      case "url":
        return href === value;
      default:
        return new RegExp(`^(?:${value})$`).test(href);
    }
  };
  const css = sections
    .filter(({ rules }) => rules.some(matches))
    .map((section) => section.css)
    .join("\n");
  if (css === "") {
    return;
  }

  const sheet = new CSSStyleSheet();
  sheet.replaceSync(css);
  let on = true;
  // After the page's own sheets, so equal selectors win. A page that replaces
  // its adopted sheets drops this one.
  const show = () => {
    const others = [...document.adoptedStyleSheets].filter((each) => each !== sheet);
    document.adoptedStyleSheets = on ? [...others, sheet] : others;
  };
  const keep = () => {
    if (on !== [...document.adoptedStyleSheets].includes(sheet)) {
      show();
    }
  };
  show();
  document.addEventListener("DOMContentLoaded", keep);
  addEventListener("load", keep);

  const set = ({ off = [] }) => {
    on = !off.includes(hostname);
    keep();
  };
  chrome.storage.local.get("off").then(set);
  chrome.storage.onChanged.addListener((changes) => {
    if (changes.off !== undefined) {
      set({ off: changes.off.newValue });
    }
  });
};
