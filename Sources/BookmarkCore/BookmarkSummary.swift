import Foundation

/// Sidebar totals are independent of the active search and unread filter.
public struct BookmarkSummary {
    public private(set) var favorites = 0
    public private(set) var inbox = 0
    public private(set) var topicCounts: [String: Int] = [:]
    public var topics: [String] { topicCounts.keys.sorted() }

    public init(_ bookmarks: [Bookmark]) {
        for bookmark in bookmarks {
            if bookmark.isFavorite { favorites += 1 }
            if let topic = bookmark.topics.first { topicCounts[topic, default: 0] += 1 }
            else { inbox += 1 }
        }
    }
}
