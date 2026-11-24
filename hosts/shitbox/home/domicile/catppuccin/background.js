// A click on the button turns the styles off on the site, or on again.
chrome.action.onClicked.addListener(async ({ url }) => {
  if (url === undefined || !URL.canParse(url)) {
    return;
  }
  const { hostname } = new URL(url);
  const { off = [] } = await chrome.storage.local.get("off");
  await chrome.storage.local.set({
    off: off.includes(hostname) ? off.filter((each) => each !== hostname) : [...off, hostname],
  });
});
