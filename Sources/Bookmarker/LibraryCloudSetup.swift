import Foundation

/// The app uses an ordinary portable folder in iCloud Drive, not a private CloudKit database.
enum LibraryCloudSetup {
    static var defaultLocalFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Bookmarker/Library", isDirectory: true)
    }
    static func cloudFolder() -> URL? {
        let drive = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: drive.path, isDirectory: &directory), directory.boolValue else { return nil }
        return drive.appendingPathComponent("Bookmarker/Library", isDirectory: true)
    }
    /// Copy first, then switch. Originals remain available if iCloud or the app stops midway.
    static func copyLibrary(from source: URL, to destination: URL) throws {
        guard source.standardizedFileURL != destination.standardizedFileURL else { return }
        let fm = FileManager.default
        let sourceParts = source.resolvingSymlinksInPath().pathComponents
        let destinationParts = destination.resolvingSymlinksInPath().pathComponents
        guard !destinationParts.starts(with: sourceParts), !sourceParts.starts(with: destinationParts) else { throw CocoaError(.fileWriteInvalidFileName) }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try CoordinatedFiles.read(source) { source in
            try CoordinatedFiles.write(destination) { destination in
                guard let files = fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: .skipsHiddenFiles) else { throw CocoaError(.fileReadUnknown) }
                // Validate all collisions before writing anything.
                var copies: [(URL, Data)] = []
                for case let file as URL in files {
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                    let parts = file.resolvingSymlinksInPath().pathComponents
                    let root = source.resolvingSymlinksInPath().pathComponents
                    guard parts.starts(with: root) else { continue }
                    let relative = parts.dropFirst(root.count).joined(separator: "/")
                    guard !relative.contains("/"), relative.hasSuffix(".json") else { continue }
                    let target = destination.appendingPathComponent(relative)
                    let data = try Data(contentsOf: file)
                    if fm.fileExists(atPath: target.path) {
                        if relative.hasSuffix(".json"), try Data(contentsOf: target) != data {
                            throw SetupError.collision(relative)
                        }
                        continue
                    }
                    // An evicted destination is an existing file too; never overwrite its placeholder.
                    let placeholder = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).icloud")
                    guard !fm.fileExists(atPath: placeholder.path) else { throw SetupError.collision(relative) }
                    copies.append((target, data))
                }
                for (target, data) in copies {
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: target, options: .atomic)
                }
            }
        }
    }
    enum SetupError: LocalizedError {
        case collision(String)
        var errorDescription: String? {
            switch self {
            case .collision(let name): "The iCloud library already has a different or undownloaded copy of \(name). Your current library was kept. Download and reconcile the existing file before trying again."
            }
        }
    }
}
