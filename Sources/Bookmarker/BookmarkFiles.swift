import BookmarkCore
import Foundation

enum BookmarkFiles {
    struct Saved: Sendable {
        let bookmark: Bookmark
        let data: Data
    }

    static func save(_ bookmark: Bookmark, to file: URL, expected: Data?) throws -> Saved? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var updated = bookmark
        updated.updatedAt = Date()
        let data = try encoder.encode(updated)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        updated = try decoder.decode(Bookmark.self, from: data)
        let saved = try CoordinatedFiles.write(file) { coordinatedURL in
            guard (try? Data(contentsOf: coordinatedURL)) == expected else { return false }
            try data.write(to: coordinatedURL, options: .atomic)
            return true
        }
        return saved ? Saved(bookmark: updated, data: data) : nil
    }
}
