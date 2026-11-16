import BookmarkCore
import Foundation

@main struct LibraryChecks {
    @MainActor static func main() async throws {
        try await checkSharedReadingCopies()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BookmarkerChecks-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = Library(folder: folder)
        precondition(LibrarySyncStatus.inspect(folder) == .local, "A local library must never show a green iCloud tick")
        var bookmark = Bookmark(url: "https://example.com", title: "Original", notes: "First comment")
        precondition(library.save(bookmark))
        library.reload()
        let saved = library.bookmarks
        library.reload()
        precondition(library.bookmarks == saved, "Unchanged reload must preserve records")

        let file = folder.appendingPathComponent("\(bookmark.id.uuidString).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        bookmark.title = "External title"
        try encoder.encode(bookmark).write(to: file, options: .atomic)
        library.reload()
        precondition(
            library.bookmarks.first?.title == "External title", "External edits must invalidate cached records")

        var stale = library.bookmarks[0]
        bookmark.notes = "External comment"
        let external = try encoder.encode(bookmark)
        try external.write(to: file, options: .atomic)
        stale.notes = "Stale overwrite"
        precondition(!library.save(stale), "Saving a stale snapshot must fail")
        let afterConflict = try Data(contentsOf: file)
        precondition(afterConflict == external, "External changes must remain untouched")
        precondition(library.bookmarks.first?.notes == "External comment")
        library.update(bookmark.id) { $0.isFavorite = true }
        library.reload()
        precondition(library.bookmarks.first?.isFavorite == true)
        precondition(library.bookmarks.first?.notes == "External comment")

        let reader = folder.appendingPathComponent("\(bookmark.id.uuidString).reader.html")
        let cachedHTML = "<html><body><main>Offline reading copy</main></body></html>"
        try cachedHTML.write(to: reader, atomically: true, encoding: .utf8)
        let loadedHTML = try await library.readerHTML(bookmark.id)
        precondition(loadedHTML == cachedHTML, "Saved reading copies must load without a network request")
        precondition(
            library.cachedReaderHTML(bookmark.id) == cachedHTML,
            "Recently viewed articles must be available from the bounded memory cache")
        await library.migrateReadingCopies()
        let organizedReader = library.readingCopiesFolder.appendingPathComponent(
            "\(bookmark.id.uuidString).reader.html")
        precondition(FileManager.default.fileExists(atPath: organizedReader.path))
        precondition(!FileManager.default.fileExists(atPath: reader.path))
        let previousCopies = folder.appendingPathComponent("Reading Copies")
        try FileManager.default.createDirectory(at: previousCopies, withIntermediateDirectories: true)
        try cachedHTML.write(
            to: previousCopies.appendingPathComponent("\(bookmark.id.uuidString).reader.html"), atomically: true,
            encoding: .utf8)
        await library.migrateReadingCopies()
        precondition(
            !FileManager.default.fileExists(atPath: previousCopies.path),
            "Legacy iCloud reading folders must leave the library")
        precondition(FileManager.default.fileExists(atPath: organizedReader.path))
        precondition(library.readingCopyCount == 1 && library.readingCopyBytes == cachedHTML.utf8.count)
        let migratedHTML = try await library.readerHTML(bookmark.id)
        precondition(migratedHTML == cachedHTML)
        library.downloadAllReadingCopies()
        for _ in 0..<200 {
            if !library.downloadProgress.running { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(
            !library.downloadProgress.running && library.downloadProgress.completed == 1
                && library.downloadProgress.failed == 0, "Bulk saving must reuse existing offline files")

        let undo = UndoManager()
        undo.groupsByEvent = false
        library.undoManager = undo
        let topicA = Bookmark(url: "https://example.com/topic-a", topics: ["Before"], notes: "Keep notes")
        let topicB = Bookmark(url: "https://example.com/topic-b", topics: ["Before"])
        precondition(library.save(topicA) && library.save(topicB))
        precondition(library.renameTopic("Before", to: " After "))
        precondition(library.bookmarks.filter { $0.topics == ["After"] }.count == 2)
        precondition(library.bookmarks.first(where: { $0.id == topicA.id })?.notes == "Keep notes")
        undo.undo()
        precondition(library.bookmarks.filter { $0.topics == ["Before"] }.count == 2)
        undo.redo()
        precondition(library.bookmarks.filter { $0.topics == ["After"] }.count == 2)
        precondition(!library.renameTopic("After", to: "   "))
        precondition(library.remove(topicA.id) && library.remove(topicB.id))
        undo.removeAllActions()
        library.update(bookmark.id) { $0.isRead = true }
        precondition(undo.canUndo && library.bookmarks.first?.isRead == true)
        undo.undo()
        precondition(library.bookmarks.first?.isRead == false && undo.canRedo)
        undo.redo()
        precondition(library.bookmarks.first?.isRead == true)
        undo.removeAllActions()
        library.update(bookmark.id, actionName: "Move Bookmark") { $0.move(to: "Design") }
        precondition(library.bookmarks.first?.topics == ["Design"])
        undo.undo()
        precondition(library.bookmarks.first?.topics.isEmpty == true)
        undo.redo()
        precondition(library.bookmarks.first?.topics == ["Design"])
        library.update(bookmark.id, actionName: "Move Bookmark") { $0.move(to: nil) }
        precondition(library.bookmarks.first?.topics.isEmpty == true)
        undo.undo()
        precondition(library.bookmarks.first?.topics == ["Design"])
        // Restore the original read-state undo scenario.
        undo.removeAllActions()
        library.update(bookmark.id) { $0.isRead = false }
        undo.removeAllActions()
        library.update(bookmark.id) { $0.isRead = true }
        // Website metadata can finish between a user action and Undo.
        var enriched = library.bookmarks[0]
        enriched.pageDescription = "Fresh metadata"
        enriched.readingMinutes = 7
        precondition(library.save(enriched))
        undo.undo()
        precondition(library.bookmarks.first?.isRead == false)
        precondition(library.bookmarks.first?.pageDescription == "Fresh metadata")
        precondition(library.bookmarks.first?.readingMinutes == 7)
        // Undo must preserve later edits from another Mac or agent.
        library.update(bookmark.id) { $0.isRead = true }
        var externalEdit = library.bookmarks[0]
        externalEdit.notes = "Changed on another Mac"
        try encoder.encode(externalEdit).write(to: file, options: .atomic)
        undo.undo()
        precondition(library.bookmarks.first?.isRead == true)
        precondition(library.bookmarks.first?.notes == "Changed on another Mac")
        undo.removeAllActions()

        var second = Bookmark(url: "https://example.com/second", topics: ["Original topic"])
        second.isFavorite = false
        precondition(library.save(second))
        let ids: Set<UUID> = [bookmark.id, second.id]
        let originalTopics = Dictionary(uniqueKeysWithValues: library.bookmarks.map { ($0.id, $0.topics) })
        undo.removeAllActions()
        library.update(ids, actionName: "Move Bookmarks") { $0.move(to: "Batch topic") }
        precondition(library.bookmarks.allSatisfy { $0.topics == ["Batch topic"] })
        undo.undo()
        precondition(Dictionary(uniqueKeysWithValues: library.bookmarks.map { ($0.id, $0.topics) }) == originalTopics)
        precondition(!undo.canUndo && undo.canRedo, "A batch move must undo in one step")
        undo.redo()
        precondition(library.bookmarks.allSatisfy { $0.topics == ["Batch topic"] })
        undo.undo()
        undo.removeAllActions()
        let beforeNoOp = library.bookmarks
        library.update(second.id) { $0.move(to: "Original topic") }
        precondition(
            library.bookmarks == beforeNoOp && !undo.canUndo,
            "Dropping into the same topic must not create an undo action")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("\(second.id.uuidString).json"))
        library.reload()

        // Background scans must notice external edits and preserve in-flight user edits.
        var backgroundEdit = library.bookmarks[0]
        backgroundEdit.notes = "Background scan check"
        try encoder.encode(backgroundEdit).write(to: file, options: .atomic)
        await library.reloadInBackground()
        precondition(library.bookmarks[0].notes == "Background scan check")
        let pendingScan = Task { await library.reloadInBackground() }
        await Task.yield()
        library.update(bookmark.id) { $0.notes = "Edit during background scan" }
        await pendingScan.value
        precondition(library.bookmarks[0].notes == "Edit during background scan")

        // File presenter notifications must reload without a polling timer.
        var notified = library.bookmarks[0]
        notified.notes = "Presenter notification"
        try encoder.encode(notified).write(to: file, options: .atomic)
        for _ in 0..<100 {
            if library.bookmarks.first?.notes == notified.notes { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        precondition(
            library.bookmarks.first?.notes == notified.notes, "Native file notifications must reload external edits")

        // An extension request must reuse existing bookmarks after reloading external state.
        var externalSafari = library.bookmarks[0]
        externalSafari.url = "https://example.com/safari-already-saved"
        try encoder.encode(externalSafari).write(to: file, options: .atomic)
        let saveRequest = BookmarkSaveRequest(
            url: URL(string: "bookmarker://save?url=https%3A%2F%2Fexample.com%2Fsafari-already-saved&title=Safari")!)!
        let safariID = await library.addFromSafari(saveRequest)
        precondition(
            safariID == externalSafari.id && library.bookmarks.count == 1,
            "Safari requests must reload before duplicate detection")

        // Backups preserve JSON (including comments), skip daily duplicates, and rotate.
        let backupRoot = folder.deletingLastPathComponent().appendingPathComponent("BackupChecks-\(UUID())")
        let now = Date()
        try LibraryBackup.create(source: folder, destination: backupRoot, force: true, now: now)
        let firstBackup = try LibraryBackup.snapshots(in: backupRoot)
        precondition(firstBackup.count == 1)
        let backupData = try Data(contentsOf: firstBackup[0].appendingPathComponent(file.lastPathComponent))
        let originalData = try Data(contentsOf: file)
        precondition(backupData == originalData)
        try LibraryBackup.create(source: folder, destination: backupRoot, force: false, now: now)
        let skippedBackups = try LibraryBackup.snapshots(in: backupRoot)
        precondition(skippedBackups.count == 1)
        for day in 1...9 {
            try LibraryBackup.create(
                source: folder, destination: backupRoot, force: true, now: now.addingTimeInterval(Double(day) * 86400))
        }
        let rotatedBackups = try LibraryBackup.snapshots(in: backupRoot)
        precondition(rotatedBackups.count == 7)

        // Migration keeps the source, copies reading files and refuses conflicting IDs.
        let cloudFixture = folder.deletingLastPathComponent().appendingPathComponent("CloudChecks-\(UUID())")
        try LibraryCloudSetup.copyLibrary(from: folder, to: cloudFixture)
        let migratedData = try Data(contentsOf: cloudFixture.appendingPathComponent(file.lastPathComponent))
        precondition(migratedData == backupData)
        precondition(FileManager.default.fileExists(atPath: file.path))
        let copiedReader = cloudFixture.appendingPathComponent("Reading Copies/\(bookmark.id.uuidString).reader.html")
        precondition(
            !FileManager.default.fileExists(atPath: copiedReader.path),
            "Reading content must never be copied into iCloud")
        try LibraryCloudSetup.copyLibrary(from: folder, to: cloudFixture)
        let conflicting = Data("different data".utf8)
        let cloudBookmark = cloudFixture.appendingPathComponent(file.lastPathComponent)
        try conflicting.write(to: cloudBookmark)
        do {
            try LibraryCloudSetup.copyLibrary(from: folder, to: cloudFixture)
            preconditionFailure("Migration must refuse a different bookmark with the same ID")
        } catch is LibraryCloudSetup.SetupError {}
        let preservedConflict = try Data(contentsOf: cloudBookmark)
        precondition(preservedConflict == conflicting)
        let preservedOriginal = try Data(contentsOf: file)
        precondition(preservedOriginal == backupData)
        try FileManager.default.removeItem(at: backupRoot)
        try FileManager.default.removeItem(at: cloudFixture)

        // A damaged file must not be silently overwritten or deleted.
        let damaged = Data("invalid json".utf8)
        try damaged.write(to: file, options: .atomic)
        library.reload()
        precondition(library.bookmarks.isEmpty && library.error != nil)
        let afterDamage = try Data(contentsOf: file)
        precondition(afterDamage == damaged)
        try external.write(to: file, options: .atomic)
        library.reload()
        precondition(library.bookmarks.count == 1)
        try FileManager.default.removeItem(at: file)
        library.reload()
        precondition(library.bookmarks.isEmpty, "External deletion must remove the cached record")
        print(
            "Passed library reload, external-edit, conflict, save, offline-reader, Undo/Redo, external-undo conflict, damaged-file and deletion checks."
        )
    }

    @MainActor static func checkSharedReadingCopies() async throws {
        final class Counter { var downloads = 0 }
        let counter = Counter()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderChecks-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let html = "<html><main>Saved article text for offline reading.</main></html>"
        let library = Library(folder: folder) { _ in
            counter.downloads += 1
            try await Task.sleep(for: .milliseconds(100))
            return html
        }
        let first = Bookmark(url: "https://example.com/article#first")
        let second = Bookmark(url: "https://example.com/article#second")
        precondition(library.save(first) && library.save(second))
        async let a = library.readerHTML(first.id)
        async let b = library.readerHTML(second.id)
        let results = try await (a, b)
        precondition(results.0 == html && results.1 == html && counter.downloads == 1)
        precondition(library.bookmarks.allSatisfy { $0.readingMinutes == 1 })
        precondition(library.cachedReaderHTML(first.id) == html && library.cachedReaderHTML(second.id) == html)
        let firstFile = library.readingCopiesFolder.appendingPathComponent("\(first.id.uuidString).reader.html")
        let secondFile = library.readingCopiesFolder.appendingPathComponent("\(second.id.uuidString).reader.html")
        let firstInode =
            try FileManager.default.attributesOfItem(atPath: firstFile.path)[.systemFileNumber] as? NSNumber
        let secondInode =
            try FileManager.default.attributesOfItem(atPath: secondFile.path)[.systemFileNumber] as? NSNumber
        precondition(firstInode != nil && firstInode == secondInode, "Shared URLs should share disk storage")
        await library.refreshReadingCopyStats()
        precondition(library.readingCopyCount == 2 && library.readingCopyBytes == html.utf8.count)
        let third = Bookmark(url: "https://example.com/shared-cancellation")
        let fourth = Bookmark(url: third.url)
        precondition(library.save(third) && library.save(fourth))
        let dismissed = Task { try await library.readerHTML(third.id, cancelOnDismiss: true) }
        while counter.downloads < 2 { await Task.yield() }
        let remaining = Task { try await library.readerHTML(fourth.id) }
        try await Task.sleep(for: .milliseconds(25))
        dismissed.cancel()
        let survivingHTML = try await remaining.value
        precondition(
            survivingHTML == html && counter.downloads == 2, "Dismissing one reader must not cancel another caller")
        _ = try? await dismissed.value
        let reopened = Library(folder: folder) { _ in
            preconditionFailure("Saved URLs must never be downloaded again")
        }
        precondition(library.remove(first.id))
        let replacement = Bookmark(url: first.url)
        precondition(reopened.save(replacement))
        let reused = try await reopened.readerHTML(replacement.id)
        precondition(reused == html)
    }
}
