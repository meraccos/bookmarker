import Foundation

/// Accessors must stay synchronous: the coordinator owns access until they return.
enum CoordinatedFiles {
    static func read<T>(_ url: URL, _ body: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in result = Result { try body(coordinatedURL) } }
        if let coordinationError { throw coordinationError }
        return try result!.get()
    }
    static func write<T>(_ url: URL, options: NSFileCoordinator.WritingOptions = [], _ body: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: options, error: &coordinationError) { coordinatedURL in result = Result { try body(coordinatedURL) } }
        if let coordinationError { throw coordinationError }
        return try result!.get()
    }
    static func data(_ url: URL) throws -> Data {
        if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
        return try read(url) { try Data(contentsOf: $0) }
    }
    static func save(_ data: Data, to url: URL) throws { try write(url) { try data.write(to: $0, options: .atomic) } }
    static func trash(_ url: URL) throws { try write(url, options: .forDeleting) { _ = try FileManager.default.trashItem(at: $0, resultingItemURL: nil) } }
}

/// Foundation delivers presenter callbacks on a serial background queue.
final class LibraryPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue = {
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()
    private let changed: @Sendable () -> Void
    init(folder: URL, changed: @escaping @Sendable () -> Void) {
        presentedItemURL = folder; self.changed = changed
        super.init()
        NSFileCoordinator.addFilePresenter(self)
    }
    func stop() { NSFileCoordinator.removeFilePresenter(self) }
    func presentedItemDidChange() { changed() }
    func presentedSubitemDidAppear(at url: URL) { changed() }
    func presentedSubitemDidChange(at url: URL) { changed() }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { changed() }
    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        changed(); completionHandler(nil)
    }
}
