import Foundation

public enum BookmarkSortOrder: String, CaseIterable, Identifiable {
    case newestAdded, oldestAdded, titleAscending, titleDescending
    public var id: Self { self }
    public var label: String {
        switch self {
        case .newestAdded: "Date Added: Newest First"
        case .oldestAdded: "Date Added: Oldest First"
        case .titleAscending: "Title: A–Z"
        case .titleDescending: "Title: Z–A"
        }
    }
    public func precedes(_ lhs: Bookmark, _ rhs: Bookmark) -> Bool {
        switch self {
        case .newestAdded, .oldestAdded:
            if lhs.createdAt != rhs.createdAt { return self == .newestAdded ? lhs.createdAt > rhs.createdAt : lhs.createdAt < rhs.createdAt }
        case .titleAscending, .titleDescending:
            let order = lhs.title.localizedStandardCompare(rhs.title)
            if order != .orderedSame { return self == .titleAscending ? order == .orderedAscending : order == .orderedDescending }
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
