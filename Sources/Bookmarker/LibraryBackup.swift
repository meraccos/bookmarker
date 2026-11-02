import Foundation
import CryptoKit

/// Local snapshots deliberately live outside iCloud, so a synced deletion cannot erase them.
enum LibraryBackup {
    static func libraryKey(for folder: URL) -> String {
        let digest = SHA256.hash(data: Data(folder.standardizedFileURL.path.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
    static func destination(for folder: URL) -> URL {
        let key = libraryKey(for: folder)
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bookmarker/Backups/\(key)", isDirectory: true)
    }
    static func snapshots(in destination: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: destination.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .filter { $0.lastPathComponent.hasPrefix("Snapshot-") }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
    @discardableResult static func create(source: URL, destination: URL, force: Bool, now: Date = Date()) throws -> Date? {
        let previous = try snapshots(in: destination)
        if !force, let latest = previous.first,
           let date = try latest.resourceValues(forKeys: [.creationDateKey]).creationDate,
           now.timeIntervalSince(date) < 24 * 60 * 60 { return date }
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let staging = destination.appendingPathComponent(".pending-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        // Coordinate the directory once for a consistent snapshot across a batch edit.
        try CoordinatedFiles.read(source) { source in
            for file in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                var name = file.lastPathComponent
                if name.hasPrefix("."), name.hasSuffix(".json.icloud") { name = String(name.dropFirst().dropLast(7)) }
                guard name.hasSuffix(".json") else { continue }
                // The directory read already owns coordinated access to its children.
                let data = try Data(contentsOf: source.appendingPathComponent(name))
                try data.write(to: staging.appendingPathComponent(name), options: .atomic)
            }
        }
        try "Bookmarker library backup\nSource: \(source.path)\nCreated: \(now.ISO8601Format())\n\nContains all bookmark JSON, including comments, topics, favorite and read state.\nReading copies are not duplicated. To recover, quit Bookmarker, preserve the current library, then copy these JSON files into the library folder.\n".write(to: staging.appendingPathComponent("Backup Info.txt"), atomically: true, encoding: .utf8)
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let completed = destination.appendingPathComponent("Snapshot-\(stamp)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.moveItem(at: staging, to: completed)
        for old in try snapshots(in: destination).dropFirst(7) { try fm.removeItem(at: old) }
        return now
    }
}
