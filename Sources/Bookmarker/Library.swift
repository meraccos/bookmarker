import SwiftUI
import BookmarkCore
import Darwin

@MainActor @Observable final class Library {
    var bookmarks: [Bookmark] = []
    let syncStatus = LibrarySyncStatus()
    var isSettingUpCloud = false
    var cloudSetupMessage: String?
    var pendingCloudBookmarks = 0
    @ObservationIgnored private var cloudRetry: Task<Void, Never>?
    @ObservationIgnored private var requestedCloudFiles: Set<URL> = []
    var backupInProgress = false
    var lastBackupDate: Date?
    var backupError: String?
    var backupsFolder: URL { LibraryBackup.destination(for: folder) }
    @ObservationIgnored private var automaticSetupAllowed = true
    var folder: URL
    var error: String?
    @ObservationIgnored weak var undoManager: UndoManager?
    var fetching: Set<UUID> = []
    var metadataMessages: [UUID: String] = [:]
    struct DownloadProgress {
        var completed = 0
        var total = 0
        var failed = 0
        var running = false
    }
    var downloadProgress = DownloadProgress()
    var readingCopyCount = 0
    var readingCopyBytes: Int64 = 0
    var readingSearchText: [UUID: String] = [:]
    @ObservationIgnored private var batchDownload: Task<Void, Never>?
    @ObservationIgnored private var batchToken = UUID()
    @ObservationIgnored private var testReadingCopiesFolder: URL?
    var readingCopiesFolder: URL { testReadingCopiesFolder ?? LocalReadingCopies.folder(for: folder) }
    private let readerCache: NSCache<NSURL, NSString> = {
        let cache = NSCache<NSURL, NSString>()
        cache.countLimit = 24; cache.totalCostLimit = 8_000_000
        return cache
    }()
    private struct ReaderDownload {
        let token: UUID
        let task: Task<String, Error>
    }
    private var readerDownloads: [String: ReaderDownload] = [:]
    private var accessURL: URL?
    private var snapshot: [String: Data] = [:]
    private var lastInvalid: [String] = []
    private var revision: UInt64 = 0
    @ObservationIgnored private var presenter: LibraryPresenter?
    @ObservationIgnored private var pendingReload: Task<Void, Never>?
    private func observeFolder() {
        cloudRetry?.cancel()
        requestedCloudFiles.removeAll()
        syncStatus.watch(folder)
        presenter?.stop()
        pendingReload?.cancel()
        presenter = LibraryPresenter(folder: folder) { [weak self] in
            Task { @MainActor [weak self] in self?.scheduleReload() }
        }
    }
    private func scheduleReload() {
        syncStatus.refresh()
        pendingReload?.cancel()
        pendingReload = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            await self?.reloadInBackground()
            self?.readerCache.removeAllObjects()
        }
    }
    deinit { presenter?.stop(); pendingReload?.cancel(); cloudRetry?.cancel() }
    init(folder initialFolder: URL? = nil) {
        let defaultFolder = LibraryCloudSetup.defaultLocalFolder
        folder = defaultFolder
        if let initialFolder { folder = initialFolder; automaticSetupAllowed = false; testReadingCopiesFolder = initialFolder.appendingPathComponent("Local Reading Copies") }
        else if let path = UserDefaults.standard.string(forKey: "libraryPath") { folder = URL(fileURLWithPath: path) }
        // Real libraries may contain evicted iCloud files: load them off the UI thread.
        if initialFolder != nil { reload() }
        observeFolder()
    }
    private struct Scan: Sendable {
        var bookmarks: [Bookmark]
        var snapshot: [String: Data]
        var invalid: [String]
        var pending: [URL] = []
    }
    // Keep this synchronous: the I/O policy belongs to the current thread and must
    // be restored before a Swift task can suspend or reuse that thread (Apple TN3150).
    private nonisolated static func localBookmarkData(_ file: URL) throws -> Data? {
        let policy = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        guard policy >= 0,
              setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, policy) }
        do { return try Data(contentsOf: file) }
        catch {
            var cause = error as NSError
            while true {
                if cause.domain == NSPOSIXErrorDomain && cause.code == Int(EDEADLK) { return nil }
                guard let underlying = cause.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
                cause = underlying
            }
            throw error
        }
    }
    private nonisolated static func scan(folder: URL, previous: [Bookmark], snapshot: [String: Data]) throws -> Scan {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Enumerating names must not wait for iCloud to materialize directory contents.
        let entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        // Finder may evict an iCloud file, leaving a hidden .name.json.icloud placeholder.
        let files = Set(entries.compactMap { file -> URL? in
            if file.pathExtension == "json" { return file }
            let name = file.lastPathComponent
            guard name.hasPrefix("."), name.hasSuffix(".json.icloud") else { return nil }
            return folder.appendingPathComponent(String(name.dropFirst().dropLast(7)))
        })
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let existing = Dictionary(previous.map { ($0.id.uuidString + ".json", $0) }, uniquingKeysWith: { first, _ in first })
        var result = Scan(bookmarks: [], snapshot: [:], invalid: [])
        var seen: Set<UUID> = []
        for file in files {
            do {
                let name = file.lastPathComponent
                // stat inspects local metadata without asking File Provider to download.
                // A coordinated read would wait for an evicted file before showing any rows.
                var info = stat()
                let exists = file.withUnsafeFileSystemRepresentation { path in
                    path.map { lstat($0, &info) == 0 } ?? false
                }
                if !exists || (info.st_flags & UInt32(SF_DATALESS)) != 0 {
                    result.pending.append(file)
                    if let cached = existing[name] {
                        result.bookmarks.append(cached)
                        result.snapshot[name] = snapshot[name]
                    }
                    continue
                }
                // Bookmarks are published with atomic replacement. Reading the local
                // version is sufficient here; writes still validate coordinated snapshots.
                guard let data = try localBookmarkData(file) else {
                    result.pending.append(file)
                    if let cached = existing[name] {
                        result.bookmarks.append(cached); result.snapshot[name] = snapshot[name]
                    }
                    continue
                }
                let bookmark: Bookmark
                if data == snapshot[name], let cached = existing[name] { bookmark = cached }
                else { bookmark = try decoder.decode(Bookmark.self, from: data) }
                guard bookmark.schemaVersion == 1, name == "\(bookmark.id.uuidString).json", seen.insert(bookmark.id).inserted else {
                    result.invalid.append(name); continue
                }
                result.bookmarks.append(bookmark); result.snapshot[name] = data
            } catch { result.invalid.append(file.lastPathComponent) }
        }
        result.bookmarks.sort { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt }
        result.invalid.sort()
        return result
    }
    private func apply(_ scan: Scan) {
        revision &+= 1
        if scan.bookmarks != bookmarks { bookmarks = scan.bookmarks }
        snapshot = scan.snapshot
        pendingCloudBookmarks = scan.pending.count
        requestedCloudFiles.formIntersection(Set(scan.pending))
        cloudRetry?.cancel()
        if !scan.pending.isEmpty {
            let origin = folder
            let downloads = scan.pending.filter { requestedCloudFiles.insert($0).inserted }
            Task.detached(priority: .utility) {
                for file in downloads { try? FileManager.default.startDownloadingUbiquitousItem(at: file) }
            }
            // File presenters do not reliably announce hydration on every macOS version.
            // Retry only while metadata files are pending, never while the library is idle.
            cloudRetry = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, self.folder == origin else { return }
                await self.reloadInBackground()
            }
        }
        if !scan.invalid.isEmpty && scan.invalid != lastInvalid {
            error = "Couldn’t read \(scan.invalid.joined(separator: ", ")). These files were left untouched."
        }
        lastInvalid = scan.invalid
    }
    func reload() {
        do { apply(try Self.scan(folder: folder, previous: bookmarks, snapshot: snapshot)) }
        catch { self.error = error.localizedDescription }
    }
    func reloadInBackground() async {
        let origin = folder, previous = bookmarks, snapshot = snapshot, generation = revision
        do {
            let scan = try await Task.detached(priority: .utility) {
                try Self.scan(folder: origin, previous: previous, snapshot: snapshot)
            }.value
            // Never replace an edit made while the scan was in flight.
            guard folder == origin, generation == revision, !Task.isCancelled else { return }
            apply(scan)
        } catch { if folder == origin { self.error = error.localizedDescription } }
    }
    @discardableResult func save(_ bookmark: Bookmark, actionName: String? = nil) -> Bool {
        guard !isSettingUpCloud else { return false }
        let previous = bookmarks.first(where: { $0.id == bookmark.id })
        syncStatus.refresh()
        do {
            let file = folder.appendingPathComponent("\(bookmark.id.uuidString).json")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .iso8601
            var updated = bookmark; updated.updatedAt = Date()
            let data = try encoder.encode(updated)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            updated = try decoder.decode(Bookmark.self, from: data)
            let expected = snapshot[file.lastPathComponent]
            let saved = try CoordinatedFiles.write(file) { coordinatedURL in
                guard (try? Data(contentsOf: coordinatedURL)) == expected else { return false }
                try data.write(to: coordinatedURL, options: .atomic)
                return true
            }
            guard saved else {
                reload(); error = "This bookmark changed outside the app. Its latest version has been loaded. Please try your edit again."; return false
            }
            revision &+= 1
            snapshot[file.lastPathComponent] = data
            if let index = bookmarks.firstIndex(where: { $0.id == updated.id }) { bookmarks[index] = updated } else { bookmarks.insert(updated, at: 0) }
            if let actionName { registerUndo(id: updated.id, restoring: previous, actionName: actionName) }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func addFromSafari(_ request: BookmarkSaveRequest) async -> UUID? {
        // An external URL can arrive before startup has created/loaded the library.
        repeat {
            while isSettingUpCloud {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return nil }
            }
            await reloadInBackground()
        } while isSettingUpCloud
        guard !Task.isCancelled else { return nil }
        return add(request.pageURL.absoluteString, topics: "", title: request.title)
    }
    func add(_ input: String, topics: String, title: String? = nil) -> UUID? {
        guard let url = Bookmark.normalizedURL(input) else { error = "Enter a valid http or https web address."; return nil }
        if let existing = bookmarks.first(where: { $0.url == url.absoluteString }) { return existing.id }
        let pageTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bookmark = Bookmark(url: url.absoluteString, title: pageTitle.isEmpty ? (url.host() ?? input) : String(pageTitle.prefix(4096)), topics: Self.topics(topics))
        guard save(bookmark, actionName: "Add Bookmark") else { return nil }
        let originFolder = folder
        Task {
            await refresh(bookmark.id, updateTitle: pageTitle.isEmpty)
            guard folder == originFolder, bookmarks.contains(where: { $0.id == bookmark.id }) else { return }
            do { _ = try await readerHTML(bookmark.id) }
            catch { metadataMessages[bookmark.id] = "Readable copy wasn’t saved. Open the bookmark to retry." }
        }
        return bookmark.id
    }
    func refresh(_ id: UUID, updateTitle: Bool = true) async {
        guard let bookmark = bookmarks.first(where: { $0.id == id }), let url = URL(string: bookmark.url), !fetching.contains(id) else { return }
        let originFolder = folder
        fetching.insert(id); metadataMessages[id] = nil
        defer { fetching.remove(id) }
        do {
            var request = URLRequest(url: url, timeoutInterval: 25)
            request.setValue("Bookmarker/1.0 (macOS; title fetch)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard folder == originFolder else { return }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw PreviewError.unavailable }
            guard response.mimeType?.contains("html") == true, data.count <= 8_000_000 else { throw PreviewError.unsupported }
            let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
            let (title, description) = await Task.detached(priority: .utility) {
                (ArticleParser.title(in: html), ArticleParser.description(in: html))
            }.value
            guard folder == originFolder, !Task.isCancelled else { return }
            await reloadInBackground()
            guard var latest = bookmarks.first(where: { $0.id == id }), latest.url == bookmark.url else { return }
            if updateTitle && !title.isEmpty { latest.title = title }
            latest.pageDescription = description
            _ = save(latest)
            if updateTitle && title.isEmpty { metadataMessages[id] = "No page title found. You can set a title using Edit Bookmark." }
        } catch is CancellationError { }
        catch { if !Task.isCancelled && folder == originFolder { metadataMessages[id] = "Title unavailable. \(error.localizedDescription)" } }
    }
    func cachedReaderHTML(_ id: UUID) -> String? {
        let file = readingCopiesFolder.appendingPathComponent("\(id.uuidString).reader.html")
        return readerCache.object(forKey: file as NSURL).map { $0 as String }
    }
    func readerHTML(_ id: UUID, cancelOnDismiss: Bool = false) async throws -> String {
        guard let bookmark = bookmarks.first(where: { $0.id == id }), let url = URL(string: bookmark.url) else { throw ReadablePageLoader.ReaderError.missingBookmark }
        guard !isSettingUpCloud else { throw CancellationError() }
        let originFolder = folder
        let file = readingCopiesFolder.appendingPathComponent("\(id.uuidString).reader.html")
        if let cached = cachedReaderHTML(id) { return cached }
        let legacy = originFolder.appendingPathComponent("\(id.uuidString).reader.html")
        let cached = await Task.detached(priority: .userInitiated) {
            (try? CoordinatedFiles.data(file)).flatMap { String(data: $0, encoding: .utf8) } ?? (try? CoordinatedFiles.data(legacy)).flatMap { String(data: $0, encoding: .utf8) }
        }.value
        try Task.checkCancellation()
        guard folder == originFolder else { throw CancellationError() }
        if let cached, cached.contains("<main>"), cached.contains("</main>") {
            readingSearchText[id] = ArticleParser.fullText(in: cached)
            readerCache.setObject(cached as NSString, forKey: file as NSURL, cost: cached.utf8.count)
            return cached
        }
        // Arrowing quickly through uncached entries must not launch a WebKit loader for each one.
        if cancelOnDismiss { try await Task.sleep(for: .milliseconds(150)) }
        let key = file.path
        if let pending = readerDownloads[key], !pending.task.isCancelled { return try await pending.task.value }
        let task = Task { @MainActor in
            let loader = ReadablePageLoader()
            return try await loader.load(url)
        }
        let token = UUID()
        readerDownloads[key] = ReaderDownload(token: token, task: task)
        defer { if readerDownloads[key]?.token == token { readerDownloads[key] = nil } }
        let html: String
        if cancelOnDismiss {
            html = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } else { html = try await task.value }
        try Task.checkCancellation()
        guard !isSettingUpCloud, folder == originFolder, bookmarks.contains(where: { $0.id == id && $0.url == bookmark.url }) else { throw ReadablePageLoader.ReaderError.missingBookmark }
        syncStatus.refresh()
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try CoordinatedFiles.save(Data(html.utf8), to: file)
        }.value
        guard folder == originFolder, bookmarks.contains(where: { $0.id == id && $0.url == bookmark.url }) else {
            if !FileManager.default.fileExists(atPath: originFolder.appendingPathComponent("\(id.uuidString).json").path) { try? CoordinatedFiles.write(file, options: .forDeleting) { try FileManager.default.removeItem(at: $0) } }
            throw CancellationError()
        }
        readerCache.setObject(html as NSString, forKey: file as NSURL, cost: html.utf8.count)
        readingSearchText[id] = ArticleParser.fullText(in: html)
        readingCopyCount += 1; readingCopyBytes += Int64(html.utf8.count)
        return html
    }
    @discardableResult func remove(_ id: UUID, undoable: Bool = true) -> Bool {
        guard !isSettingUpCloud, let bookmark = bookmarks.first(where: { $0.id == id }) else { return false }
        syncStatus.refresh()
        let file = folder.appendingPathComponent("\(id.uuidString).json")
        guard (try? CoordinatedFiles.data(file)) == snapshot[file.lastPathComponent] else {
            reload(); error = "This bookmark changed outside the app. Please try deleting its latest version."; return false
        }
        let preferredReader = readingCopiesFolder.appendingPathComponent("\(id.uuidString).reader.html")
        let legacyReader = folder.appendingPathComponent("\(id.uuidString).reader.html")
        let reader = FileManager.default.fileExists(atPath: preferredReader.path) ? preferredReader : legacyReader
        let copy = undoable && undoManager != nil ? try? CoordinatedFiles.data(reader) : nil
        readerCache.removeObject(forKey: preferredReader as NSURL)
        readerDownloads[preferredReader.path]?.task.cancel()
        metadataMessages[id] = nil
        readingSearchText[id] = nil
        do {
            try CoordinatedFiles.write(file, options: .forDeleting) { coordinatedURL in
                guard (try? Data(contentsOf: coordinatedURL)) == snapshot[file.lastPathComponent] else { throw CocoaError(.fileWriteFileExists) }
                _ = try FileManager.default.trashItem(at: coordinatedURL, resultingItemURL: nil)
            }
            if FileManager.default.fileExists(atPath: reader.path) {
                do { try CoordinatedFiles.trash(reader) }
                catch { self.error = "Bookmark deleted, but its reading copy couldn’t be moved to Trash: \(error.localizedDescription)" }
            }
            reload()
            if undoable { registerUndo(id: id, restoring: bookmark, reader: copy, actionName: "Delete Bookmark") }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    private func registerUndo(id: UUID, restoring bookmark: Bookmark?, reader: Data? = nil, actionName: String) {
        guard let undoManager else { return }
        let expected = bookmarks.first(where: { $0.id == id })
        let originFolder = folder
        let needsGroup = undoManager.groupingLevel == 0
        if needsGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { library in
            MainActor.assumeIsolated {
                library.restore(id: id, expected: expected, bookmark: bookmark, reader: reader, originFolder: originFolder, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
        if needsGroup { undoManager.endUndoGrouping() }
    }
    private func restore(id: UUID, expected: Bookmark?, bookmark: Bookmark?, reader: Data?, originFolder: URL, actionName: String) {
        guard folder == originFolder else { error = "Switch back to the original library to undo this change."; return }
        reload()
        let current = bookmarks.first(where: { $0.id == id })
        guard historyMatches(current, expected) else {
            error = "This bookmark has changed since that action. Undo was skipped to preserve its latest version."; return
        }
        let file = readingCopiesFolder.appendingPathComponent("\(id.uuidString).reader.html")
        let previousCopy = try? CoordinatedFiles.data(file)
        if var bookmark {
            // Background metadata is not a user edit and must survive Undo/Redo.
            if let current {
                bookmark.pageDescription = current.pageDescription
                bookmark.imageURL = current.imageURL
                bookmark.iconURL = current.iconURL
                bookmark.artworkChecked = current.artworkChecked
                if let expected, expected.title == expected.host, bookmark.title == expected.title { bookmark.title = current.title }
            }
            guard save(bookmark) else { return }
            if let reader {
                do {
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try CoordinatedFiles.save(reader, to: file)
                }
                catch { self.error = "Bookmark restored, but its offline copy couldn’t be restored: \(error.localizedDescription)" }
            }
        } else if !remove(id, undoable: false) { return }
        registerUndo(id: id, restoring: expected, reader: previousCopy, actionName: actionName)
    }
    private func historyMatches(_ current: Bookmark?, _ expected: Bookmark?) -> Bool {
        guard var current, let expected else { return current == nil && expected == nil }
        current.updatedAt = expected.updatedAt
        current.pageDescription = expected.pageDescription
        current.imageURL = expected.imageURL
        current.iconURL = expected.iconURL
        current.artworkChecked = expected.artworkChecked
        if expected.title == expected.host { current.title = expected.title }
        return current == expected
    }
    func migrateReadingCopies() async {
        let origin = folder
        do {
            let destination = readingCopiesFolder
            try await Task.detached(priority: .utility) {
                try LocalReadingCopies.migrate(from: origin, to: destination)
            }.value
            guard folder == origin else { return }
            readerCache.removeAllObjects()
            await refreshReadingCopyStats()
            await refreshReadingSearchIndex()
        } catch { if folder == origin { self.error = "Couldn’t organize reading copies: \(error.localizedDescription)" } }
    }
    func refreshReadingSearchIndex() async {
        let origin = folder, destination = readingCopiesFolder
        let ids = Set(bookmarks.map(\.id))
        let index = await Task.detached(priority: .utility) {
            var result: [UUID: String] = [:]
            let files = (try? FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent.hasSuffix(".reader.html") {
                let name = String(file.lastPathComponent.dropLast(".reader.html".count))
                guard let id = UUID(uuidString: name), ids.contains(id),
                      let data = try? Data(contentsOf: file),
                      let html = String(data: data, encoding: .utf8) else { continue }
                result[id] = ArticleParser.fullText(in: html)
            }
            return result
        }.value
        guard folder == origin, !Task.isCancelled else { return }
        readingSearchText = index
    }
    func refreshReadingCopyStats() async {
        let origin = folder, destination = readingCopiesFolder
        let usage = await Task.detached(priority: .utility) {
            let files = (try? FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let copies = files.filter { $0.lastPathComponent.hasSuffix(".reader.html") }
            let bytes = copies.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            return (copies.count, bytes)
        }.value
        guard folder == origin else { return }
        readingCopyCount = usage.0; readingCopyBytes = usage.1
    }
    func downloadAllReadingCopies() {
        guard !downloadProgress.running else { return }
        let ids = bookmarks.map(\.id)
        let origin = folder
        downloadProgress = DownloadProgress(total: ids.count, running: true)
        let token = UUID(); batchToken = token
        batchDownload = Task {
            await migrateReadingCopies()
            await withTaskGroup(of: Bool.self) { group in
                var remaining = ids.makeIterator()
                func enqueue(_ id: UUID) {
                    group.addTask {
                        do { _ = try await self.readerHTML(id, cancelOnDismiss: true); return true }
                        catch { return false }
                    }
                }
                for _ in 0..<2 { if let id = remaining.next() { enqueue(id) } }
                while let success = await group.next() {
                    guard !Task.isCancelled, folder == origin, batchToken == token else { group.cancelAll(); break }
                    downloadProgress.completed += 1
                    if !success { downloadProgress.failed += 1 }
                    if let id = remaining.next() { enqueue(id) }
                }
            }
            guard batchToken == token else { return }
            if folder == origin { downloadProgress.running = false; await refreshReadingCopyStats() }
            batchDownload = nil
        }
    }
    func cancelReadingDownloads() {
        batchDownload?.cancel()
        batchToken = UUID(); batchDownload = nil
        downloadProgress.running = false
    }
    func prepareLibrary() async {
        await reloadInBackground()
        guard !Task.isCancelled else { return }
        if automaticSetupAllowed, folder.standardizedFileURL == LibraryCloudSetup.defaultLocalFolder.standardizedFileURL {
            await useAutomaticCloudLibrary()
        }
        await backUpIfNeeded()
    }
    func backUpIfNeeded(force: Bool = false) async {
        guard !backupInProgress, !isSettingUpCloud else { return }
        backupInProgress = true
        let origin = folder, destination = backupsFolder
        defer { backupInProgress = false }
        do {
            let date = try await Task.detached(priority: .utility) {
                try LibraryBackup.create(source: origin, destination: destination, force: force)
            }.value
            guard folder == origin else { return }
            lastBackupDate = date; backupError = nil
        } catch { if folder == origin { backupError = error.localizedDescription } }
    }
    func useAutomaticCloudLibrary() async {
        guard !isSettingUpCloud, !backupInProgress else { return }
        let startingFolder = folder
        guard let destination = await Task.detached(priority: .utility, operation: { LibraryCloudSetup.cloudFolder() }).value else {
            cloudSetupMessage = "iCloud Drive isn’t available. Enable it in System Settings, then try again. Your library is saved locally."
            return
        }
        guard folder == startingFolder, !isSettingUpCloud, !backupInProgress else { return }
        guard destination.standardizedFileURL != folder.standardizedFileURL else { cloudSetupMessage = nil; return }
        isSettingUpCloud = true
        cancelReadingDownloads()
        for download in readerDownloads.values { download.task.cancel() }
        let origin = folder, backup = backupsFolder
        let oldCopies = readingCopiesFolder, newCopies = LocalReadingCopies.folder(for: destination)
        defer { isSettingUpCloud = false }
        do {
            try await Task.detached(priority: .utility) {
                try LibraryBackup.create(source: origin, destination: backup, force: true)
                try LocalReadingCopies.migrate(from: origin, to: oldCopies)
                try LocalReadingCopies.copy(from: oldCopies, to: newCopies)
                try LibraryCloudSetup.copyLibrary(from: origin, to: destination)
            }.value
            guard folder == origin else { return }
            undoManager?.removeAllActions(withTarget: self)
            readerDownloads.removeAll(); readerCache.removeAllObjects(); metadataMessages.removeAll()
            readingCopyCount = 0; readingCopyBytes = 0; lastBackupDate = nil
            accessURL?.stopAccessingSecurityScopedResource(); accessURL = nil
            folder = destination
            UserDefaults.standard.set(destination.path, forKey: "libraryPath")
            lastInvalid = []; snapshot = [:]; bookmarks = []
            pendingCloudBookmarks = 0
            observeFolder()
            isSettingUpCloud = false
            await reloadInBackground()
            cloudSetupMessage = "Using iCloud Drive. Your previous library remains at \(origin.path)."
        } catch { cloudSetupMessage = error.localizedDescription; self.error = "Couldn’t set up iCloud: \(error.localizedDescription)" }
    }
    func chooseFolder() {
        guard !isSettingUpCloud, !backupInProgress else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.message = "Choose your bookmark library folder. Use a dedicated folder in iCloud Drive to sync between Macs."; panel.prompt = "Use Library"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        undoManager?.removeAllActions(withTarget: self)
        cancelReadingDownloads()
        readingCopyCount = 0; readingCopyBytes = 0
        for download in readerDownloads.values { download.task.cancel() }
        readerDownloads.removeAll()
        readerCache.removeAllObjects()
        metadataMessages.removeAll()
        accessURL?.stopAccessingSecurityScopedResource(); _ = url.startAccessingSecurityScopedResource(); accessURL = url
        lastBackupDate = nil; backupError = nil; cloudSetupMessage = nil
        lastInvalid = []; snapshot = [:]; bookmarks = []; pendingCloudBookmarks = 0
        folder = url; UserDefaults.standard.set(url.path, forKey: "libraryPath"); observeFolder()
        Task { await reloadInBackground() }
    }
    func update(_ id: UUID, actionName: String = "Edit Bookmark", change: (inout Bookmark) -> Void) {
        guard var bookmark = bookmarks.first(where: { $0.id == id }) else { return }
        let previous = bookmark
        change(&bookmark)
        guard bookmark != previous else { return }
        _ = save(bookmark, actionName: actionName)
    }
    func update(_ ids: Set<UUID>, actionName: String, change: (inout Bookmark) -> Void) {
        undoManager?.beginUndoGrouping()
        for id in ids { update(id, actionName: actionName, change: change) }
        undoManager?.setActionName(actionName)
        undoManager?.endUndoGrouping()
    }
    @discardableResult func remove(_ ids: Set<UUID>) -> Set<UUID> {
        undoManager?.beginUndoGrouping()
        let removed = Set(ids.filter { remove($0) })
        undoManager?.setActionName(removed.count == 1 ? "Delete Bookmark" : "Delete Bookmarks")
        undoManager?.endUndoGrouping()
        return removed
    }
    static func topics(_ input: String) -> [String] {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? [] : [value]
    }
    enum PreviewError: LocalizedError { case unavailable, unsupported
        var errorDescription: String? { self == .unavailable ? "The website didn’t return a readable page." : "Only HTML pages under 8 MB are supported." }
    }
}
