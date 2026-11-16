import CryptoKit
import Foundation

/// Reading content is device-local; the portable/iCloud library contains only bookmark entries.
enum LocalReadingCopies {
    static func load(shared: URL, alias: URL, legacy: URL) throws -> String? {
        for candidate in [shared, alias, legacy] {
            guard let data = try? CoordinatedFiles.data(candidate),
                let html = String(data: data, encoding: .utf8),
                html.contains("<main>"), html.contains("</main>")
            else { continue }
            let fm = FileManager.default
            let sourceNumber = (try? fm.attributesOfItem(atPath: shared.path)[.systemFileNumber]) as? NSNumber
            let aliasNumber = (try? fm.attributesOfItem(atPath: alias.path)[.systemFileNumber]) as? NSNumber
            if candidate != shared || sourceNumber == nil || sourceNumber != aliasNumber {
                try store(data, shared: shared, aliases: [alias])
            }
            return html
        }
        return nil
    }

    /// Bookmark paths are hard links to the canonical URL copy, not duplicate text.
    /// Keep the aliases for migration, per-library statistics and Undo compatibility.
    static func store(_ data: Data, shared: URL, aliases: [URL]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: shared.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: shared.path) { try CoordinatedFiles.save(data, to: shared) }
        for alias in aliases where alias != shared {
            try fm.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Publish a replacement before removing the old alias.
            let staging = alias.deletingLastPathComponent().appendingPathComponent(".reader-\(UUID())")
            defer { try? fm.removeItem(at: staging) }
            do { try fm.linkItem(at: shared, to: staging) } catch { try fm.copyItem(at: shared, to: staging) }
            if fm.fileExists(atPath: alias.path) {
                _ = try fm.replaceItemAt(alias, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: alias)
            }
        }
    }
    /// URL identity survives deleting/re-saving a bookmark or changing libraries.
    static func sharedFile(for url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        components?.fragment = nil
        let identity = components?.url?.absoluteString ?? url.absoluteString
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bookmarker/Reading Copies/By URL/\(key).reader.html")
    }
    static func folder(for library: URL) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(
                "Bookmarker/Reading Copies/\(LibraryBackup.libraryKey(for: library))", isDirectory: true)
    }
    static func copy(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        guard fm.fileExists(atPath: source.path) else { return }
        for file in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        where file.lastPathComponent.hasSuffix(".reader.html") {
            let target = destination.appendingPathComponent(file.lastPathComponent)
            if !fm.fileExists(atPath: target.path) {
                try CoordinatedFiles.save(CoordinatedFiles.data(file), to: target)
            }
        }
    }
    static func migrate(from library: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let oldFolder = library.appendingPathComponent("Reading Copies", isDirectory: true)
        if fm.fileExists(atPath: oldFolder.path) {
            // Publish the local copies first; a failure leaves the originals untouched.
            try CoordinatedFiles.write(oldFolder, options: .forDeleting) { oldFolder in
                let files = try fm.contentsOfDirectory(at: oldFolder, includingPropertiesForKeys: nil)
                let readers = files.filter { $0.lastPathComponent.hasSuffix(".reader.html") }
                for file in readers {
                    // The directory accessor holds access while copying and removing the originals.
                    try CoordinatedFiles.save(
                        Data(contentsOf: file), to: destination.appendingPathComponent(file.lastPathComponent))
                }
                if readers.count == files.count {
                    _ = try fm.trashItem(at: oldFolder, resultingItemURL: nil)
                } else {
                    for file in readers { _ = try fm.trashItem(at: file, resultingItemURL: nil) }
                }
            }
        }
        for file in try fm.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)
        where file.lastPathComponent.hasSuffix(".reader.html") {
            let target = destination.appendingPathComponent(file.lastPathComponent)
            try CoordinatedFiles.write(file, options: .forDeleting) { file in
                try CoordinatedFiles.save(Data(contentsOf: file), to: target)
                _ = try fm.trashItem(at: file, resultingItemURL: nil)
            }
        }
    }
}
