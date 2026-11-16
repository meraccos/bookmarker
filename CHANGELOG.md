# Changelog

## 0.4.0

- Show estimated reading time beside the article menu, using 200 words per minute.
- Sort bookmarks by shortest or longest reading time.
- Drag sidebar topics to reorder them and remember the order between launches.
- Right-click a topic to rename it across all its bookmarks, with Undo/Redo support.
- Reuse downloaded articles by URL, share storage between matching URLs, and keep existing copies available offline.
- Fix shared-download cancellation, cache invalidation, disk accounting, and background metadata handling in Undo.
- Move comment and metadata writes off the UI thread, simplify view organization, and standardize formatting and release builds.

Requires macOS 14 or later. The downloadable app is built for Apple Silicon and ad-hoc signed, not notarized. Safari's extension requires Allow unsigned extensions for this development build.
