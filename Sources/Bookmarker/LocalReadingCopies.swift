import Foundation

/// Reading content is device-local; the portable/iCloud library contains only bookmark entries.
enum LocalReadingCopies {
    static func folder(for library: URL) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bookmarker/Reading Copies/\(LibraryBackup.libraryKey(for: library))", isDirectory: true)
    }
    static func copy(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        guard fm.fileExists(atPath: source.path) else { return }
        for file in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) where file.lastPathComponent.hasSuffix(".reader.html") {
            let target = destination.appendingPathComponent(file.lastPathComponent)
            if !fm.fileExists(atPath: target.path) { try CoordinatedFiles.save(CoordinatedFiles.data(file), to: target) }
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
                    try CoordinatedFiles.save(Data(contentsOf: file), to: destination.appendingPathComponent(file.lastPathComponent))
                }
                if readers.count == files.count {
                    _ = try fm.trashItem(at: oldFolder, resultingItemURL: nil)
                } else {
                    for file in readers { _ = try fm.trashItem(at: file, resultingItemURL: nil) }
                }
            }
        }
        for file in try fm.contentsOfDirectory(at: library, includingPropertiesForKeys: nil) where file.lastPathComponent.hasSuffix(".reader.html") {
            let target = destination.appendingPathComponent(file.lastPathComponent)
            try CoordinatedFiles.write(file, options: .forDeleting) { file in
                try CoordinatedFiles.save(Data(contentsOf: file), to: target)
                _ = try fm.trashItem(at: file, resultingItemURL: nil)
            }
        }
    }
}
