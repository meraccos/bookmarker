const menuID = "save-to-bookmarker";

async function registerMenu() {
  // Safari can discard an extension's registered menus when an unsigned local
  // build is disabled or the background worker is replaced. Rebuild the menu
  // whenever the worker starts instead of relying on the one-time install event.
  await browser.contextMenus.removeAll();
  browser.contextMenus.create({
    id: menuID,
    title: "Save to Bookmarker",
    contexts: ["page", "selection", "link", "image", "video", "audio"],
    documentUrlPatterns: ["http://*/*", "https://*/*"]
  });
}

browser.runtime.onInstalled.addListener(registerMenu);
browser.runtime.onStartup.addListener(registerMenu);
registerMenu().catch(error => console.error("Could not register Bookmarker menu:", error));

browser.contextMenus.onClicked.addListener(async (info, tab) => {
  if (info.menuItemId !== menuID) return;
  const url = info.pageUrl || tab?.url;
  if (!url || !/^https?:\/\//i.test(url)) return;
  try {
    const response = await browser.runtime.sendNativeMessage("local.bookmarker.app", {
      url,
      title: tab?.title || ""
    });
    if (!response?.ok) throw new Error(response?.error || "Bookmarker could not receive the save request.");
  } catch (error) {
    console.error("Bookmarker save failed:", error);
    await browser.tabs.create({
      url: browser.runtime.getURL("save-error.html") + "?message=" + encodeURIComponent(error.message || String(error))
    });
  }
});
