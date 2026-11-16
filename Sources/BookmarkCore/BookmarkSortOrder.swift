import Foundation

public enum BookmarkSortOrder: String, CaseIterable, Identifiable {
    case newestAdded, oldestAdded, titleAscending, titleDescending, shortestReadingTime, longestReadingTime
    public var id: Self { self }
    public var label: String {
        switch self {
        case .newestAdded: "Date Added: Newest First"
        case .oldestAdded: "Date Added: Oldest First"
        case .titleAscending: "Title: A–Z"
        case .titleDescending: "Title: Z–A"
        case .shortestReadingTime: "Reading Time: Shortest First"
        case .longestReadingTime: "Reading Time: Longest First"
        }
    }
    public func precedes(_ lhs: Bookmark, _ rhs: Bookmark) -> Bool {
        switch self {
        case .shortestReadingTime, .longestReadingTime:
            switch (lhs.readingMinutes, rhs.readingMinutes) {
            case (let left?, let right?) where left != right:
                return self == .shortestReadingTime ? left < right : left > right
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
        case .newestAdded, .oldestAdded:
            if lhs.createdAt != rhs.createdAt {
                return self == .newestAdded ? lhs.createdAt > rhs.createdAt : lhs.createdAt < rhs.createdAt
            }
        case .titleAscending, .titleDescending:
            let order = lhs.title.localizedStandardCompare(rhs.title)
            if order != .orderedSame {
                return self == .titleAscending ? order == .orderedAscending : order == .orderedDescending
            }
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
