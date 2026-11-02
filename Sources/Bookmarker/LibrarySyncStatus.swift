import Foundation
import Observation

@MainActor @Observable final class LibrarySyncStatus {
    enum State: Equatable, Sendable { case checking, local, syncing, uploaded, problem(String) }
    private(set) var state: State = .checking
    @ObservationIgnored private var folder: URL?
    @ObservationIgnored private var query: NSMetadataQuery?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var check: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    func watch(_ folder: URL) {
        query?.stop()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        self.folder = folder
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope, NSMetadataQueryUbiquitousDataScope]
        query.predicate = NSPredicate(format: "%K BEGINSWITH %@", NSMetadataItemPathKey, folder.path + "/")
        query.notificationBatchingInterval = 0.5
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            })
        }
        self.query = query
        query.start()
        refresh()
    }
    func refresh() {
        state = .checking
        check?.cancel()
        let token = UUID(); generation = token
        guard let folder else { return }
        check = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            let result = await Task.detached(priority: .utility) { Self.inspect(folder) }.value
            guard let self, !Task.isCancelled, generation == token else { return }
            state = result
        }
    }
    nonisolated static func inspect(_ folder: URL) -> State {
        do {
            let root = try folder.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemIsUploadingKey, .ubiquitousItemIsDownloadingKey, .ubiquitousItemHasUnresolvedConflictsKey, .ubiquitousItemUploadingErrorKey, .ubiquitousItemDownloadingErrorKey])
            guard root.isUbiquitousItem == true else { return .local }
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isUbiquitousItemKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey, .ubiquitousItemIsDownloadingKey, .ubiquitousItemHasUnresolvedConflictsKey, .ubiquitousItemUploadingErrorKey, .ubiquitousItemDownloadingErrorKey]
            var enumerationError: String?
            guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, error in enumerationError = error.localizedDescription; return false }) else { return .problem("Couldn’t check library files.") }
            if root.ubiquitousItemHasUnresolvedConflicts == true { return .problem("The library has conflicting iCloud versions.") }
            if let error = root.ubiquitousItemUploadingError ?? root.ubiquitousItemDownloadingError { return .problem(error.localizedDescription) }
            var pending = root.ubiquitousItemIsUploading == true || root.ubiquitousItemIsDownloading == true
            for case let file as URL in files {
                let values = try file.resourceValues(forKeys: keys)
                if values.ubiquitousItemHasUnresolvedConflicts == true { return .problem("An iCloud file has conflicting versions.") }
                if let error = values.ubiquitousItemUploadingError ?? values.ubiquitousItemDownloadingError { return .problem(error.localizedDescription) }
                if values.ubiquitousItemIsUploading == true || values.ubiquitousItemIsDownloading == true { pending = true }
                if values.isDirectory == true { continue }
                // Never infer upload completion from an empty transfer queue or missing metadata.
                if values.isUbiquitousItem != true || values.ubiquitousItemIsUploaded != true || values.ubiquitousItemIsUploading == true || values.ubiquitousItemIsDownloading == true { pending = true }
            }
            if let enumerationError { return .problem(enumerationError) }
            return pending ? .syncing : .uploaded
        } catch { return .problem(error.localizedDescription) }
    }
}
