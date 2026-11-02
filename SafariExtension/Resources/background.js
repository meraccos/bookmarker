const menuID = "save-to-bookmarker";

browser.runtime.onInstalled.addListener(() => {
  browser.contextMenus.create({
    id: menuID,
    title: "Save to Bookmarker",
    contexts: ["page", "selection", "link", "image", "video", "audio"],
    documentUrlPatterns: ["http://*/*", "https://*/*"]
  });
});

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
