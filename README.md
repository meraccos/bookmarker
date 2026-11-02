# Bookmarker

A small native macOS bookmark library. SwiftUI, macOS 14+, no dependencies or account.

## Run

```sh
./scripts/build-app.sh
open dist/Bookmarker.app
```

Drag `dist/Bookmarker.app` to Applications if desired. The local build is ad-hoc signed; distribution to other Macs may require opening via Finder's Open command. Requires Swift 6+ to build; full Xcode is not required.

## First iteration

- Add a URL with ⌘N. Its title is fetched in the background; the list shows the website link above each title, with clickable favorite and read status icons. Single/double-clicking a row stays in Bookmarker; Open Original and the menu’s Open in Browser action open the website.
- The list is text-only, with subtle separators. Legacy artwork fields remain compatible with existing library files; images are no longer downloaded or displayed.
- Page descriptions appear below titles, using HTML `description` metadata with Open Graph/Twitter fallbacks. Short descriptions display fully; longer descriptions truncate to two lines with an ellipsis. Pages without descriptions leave this space out. The full text stays in the portable `pageDescription` field and is searchable. Existing bookmarks fetch descriptions on the next launch.
- Search titles, descriptions, URLs, topics, and comments. Press ⌘F to focus search.
- The sort menu beside the unread filter offers date added (newest/oldest first) and title (A–Z/Z–A). Newest added is the default; your choice is remembered across sections and launches. Editing a bookmark does not change its saved date.
- Right-click a bookmark to add/remove Favorites, mark it read/unread, or move it to Inbox or a topic. Favorites appears directly below All bookmarks.
- Select a range with Shift-click, or toggle individual entries with ⌘-click. Delete removes the selected entries; right-click menus and dragging apply to the selection. Batch moves and deletes undo with one ⌘Z.
- Drag a bookmark into Inbox or a topic in the sidebar to move it. Dropping onto Favorites stars it without changing its location. Two-finger trackpad swipes remain available for read/delete actions.
- A bookmark has exactly one location: Inbox (no topic) or one topic. Moving replaces its previous topic. Create a topic from the Move to → New Topic… menu.
- All sidebar rows show total item counts right-aligned after their names, including zero. The Unread button at the top filters every section (All bookmarks, Favorites, Inbox, and topics) to unread items while sidebar totals remain unchanged. The button stays active when switching sections.
- Write comments in the editor below the reading view; changes save automatically as you type. Comments use the existing `notes` field in the portable JSON format.
- Edit Bookmark is available in the entry’s native right-click menu and the right panel’s three-dot menu. Both menus include favorite, read/unread, and topic moves. Location appears subtly beside the saved date in the footer.
- The right panel contains a large independently scrollable reading view above Comments. It downloads the webpage in an isolated, nonpersistent WebKit session, extracts readable text, and displays it with a consistent font. The readable HTML is saved locally at `~/Library/Application Support/Bookmarker/Reading Copies/<library-key>/<UUID>.reader.html`, outside iCloud, and opens offline on this Mac. New bookmarks save this copy automatically in the background; existing bookmarks save it the first time they are opened. Each Mac downloads its own reading copies; only bookmark entries sync. This is a text reading copy, not a full website archive; inaccessible or paywalled pages may not be saved. Pages that cannot load or expose readable text show a retry option; Read original opens the website in your browser.
- Edit the topic using either bookmark menu. Existing files with multiple topics use the first topic in their array; the next save writes that single topic.
- Open original articles in your default browser. Use Refresh Website Details from the detail or right-click menu to update the title and description.
- Swipe left on a bookmark to reveal a red Delete button (moves the bookmark and its saved reading copy to macOS Trash). Swipe right to mark it read/unread; a full swipe performs that status action.
- Undo bookmark additions, edits, favorite/read changes, topic moves, and deletions with ⌘Z; redo with ⇧⌘Z. Comment editing uses the text editor’s normal undo. Undo refuses to overwrite a newer external edit.
- Choose a library folder from Bookmarker → Settings… (⌘,). This switches libraries; it does not copy the current library. To migrate, move/copy the JSON files in Finder, then choose that folder.

## Portable library / iCloud Drive

On first launch, Bookmarker automatically uses `iCloud Drive/Bookmarker/Library` when iCloud Drive is available. An existing default local library is backed up, copied to iCloud (JSON entries only), and kept in its original location. On another Mac with the same iCloud account and iCloud Drive enabled, the app finds the same standard folder. If iCloud Drive is unavailable, the library stays at `~/Library/Application Support/Bookmarker/Library`; Settings offers **Use Automatic iCloud Library** to retry later. A manually selected custom library remains selected until you change it. Migration refuses conflicting IDs rather than overwriting either copy.

The sidebar footer reports local storage, checking, syncing, upload completion, or sync errors. A green tick means iCloud reports the current library files uploaded; it does not guarantee another Mac has downloaded them or that all system transfers have finished. Local reading-copy downloads do not affect the iCloud status. The app uses native NSFileCoordinator access for bookmark and local reading-copy files, and NSFilePresenter notifications to reload external changes without periodic polling. Changes are coalesced and scanned off the UI thread; unchanged records reuse their decoded data. iCloud placeholders request download when read. Finder’s Keep Downloaded option is useful for offline access.

Each bookmark is an independent UTF-8 JSON file named `<UUID>.json`:

```json
{
  "schemaVersion": 1,
  "id": "B84855F7-F082-4A6A-8C81-6B6582BC3426",
  "url": "https://example.com/article",
  "title": "An interesting article",
  "preview": "",
  "topics": ["Design"],
  "isFavorite": false,
  "isRead": false,
  "notes": "Why I saved this",
  "createdAt": "2026-11-01T12:00:00Z",
  "updatedAt": "2026-11-01T12:00:00Z"
}
```

An AI agent can organize files by editing `topics` (an empty array for Inbox, or an array containing exactly one topic name) and `notes`, and updating `updatedAt` in ISO 8601 UTC. Preserve IDs, filenames, schemaVersion, URLs, and creation dates. Use atomic file replacements and keep backups before bulk edits. The app leaves unreadable files untouched and reports them.

Separate files reduce unrelated sync conflicts. Changes detected before saving cause the app to reload rather than overwrite the external change. This is folder sync, not a transactional cloud database: simultaneous edits of the same bookmark on two Macs can still create iCloud conflicts. Prefer editing a given bookmark on one Mac at a time and let iCloud finish syncing.

Existing `Reading Copies` folders inside an older library are migrated to local storage and moved out of the iCloud library. New downloads never write reading content into iCloud.

## Backups

The app keeps seven daily local snapshots under `~/Library/Application Support/Bookmarker/Backups`, separated by library path. It checks on launch and hourly while open; **Back Up Now** creates an immediate snapshot. **Show Backups** opens them in Finder. A completed snapshot is published atomically before older ones are rotated. Backups contain all bookmark JSON, including comments, topics, favorites and read state, but do not duplicate regenerable reading HTML. Each snapshot includes recovery instructions. Backups stay outside iCloud so a synchronized deletion cannot delete the backup. A separate pre-migration snapshot is made before copying a library to iCloud.

For recovery, quit Bookmarker, preserve the current library folder, and copy the desired snapshot’s JSON files into the library folder. Replacing a file restores that bookmark; merging a snapshot does not remove newer bookmarks. Allow iCloud to finish before editing the restored library on another Mac.

## Title fetching

The app fetches public HTML directly from the saved website to read its page title and description; it does not send links to an AI service. JavaScript-only pages, paywalls, anti-bot pages, or unusual encodings may prevent title fetching. Set a title manually using Edit Bookmark if needed. Only HTML responses under 8 MB are parsed, although the response is downloaded before that size check. Existing preview fields remain in portable files for compatibility but are neither displayed, searched, nor refreshed.

## Verification

```sh
./scripts/swift.sh run BookmarkChecks
./scripts/check-library.sh
```

Dependency-free checks (runnable without Xcode’s test frameworks) cover article extraction, two-sentence truncation, HTML entity decoding, URL validation, portable JSON round-tripping, legacy HTML layouts, backward-compatible status defaults, exclusive Inbox/topic moves, image metadata precedence, relative image URLs, icon fallbacks, and HTML description extraction.

Persistence checks use a temporary library and cover external edits/deletions, conflict protection, damaged-file preservation, local saves, and offline reading copies.

## Safari right-click extension

The build includes `BookmarkerSafari.appex`. Once enabled in Safari Settings → Extensions, right-click a webpage and choose **Save to Bookmarker**. The containing app opens and saves that page into Inbox (or reuses an existing bookmark for the same URL). It uses the page URL and title; no content scripts are injected. Saving reveals the bookmark in All bookmarks and clears search/unread filters. An already-saved page keeps its existing topic and is selected rather than duplicated. Handoff failures open an extension error page. Normal HTML metadata fetching and offline-copy saving then run in the app.

This local build is ad-hoc signed. Safari requires **Allow unsigned extensions** in its Developer settings to run it without an Apple developer signing identity. That is a user-controlled development setting; the build script does not change Safari’s security settings. For a signed build, set `BOOKMARKER_SIGNING_IDENTITY` to an installed signing identity before running `scripts/build-app.sh`.

The Safari web extension requests `activeTab`, `contextMenus`, and `nativeMessaging` only. It has no all-sites host permissions, history API permission, content scripts, or general tabs permission. Safari describes its access as the current tab’s webpage when you use the extension. Safari’s internal pages and non-HTTP(S) URLs are unsupported.

## Responsiveness and offline downloads

The list uses native selection, context menus, separators, and swipe actions. Unchanged rows skip content updates. One WKWebView is reused when switching articles, with a bounded cache of 24 reading copies (up to 8 MB). Rapid navigation cancels unneeded reading downloads. File-change-triggered directory scans and reading-copy I/O run off the main actor.

Settings → Offline reading can download all missing readable copies in the background, two at a time. Existing copies are reused; inaccessible pages are counted as unavailable. Cancel stops the queue, and Download All Missing Copies resumes by checking existing files. Existing `.reader.html` files migrate out of the library into local storage on launch. Settings shows the copy count and actual disk usage.
