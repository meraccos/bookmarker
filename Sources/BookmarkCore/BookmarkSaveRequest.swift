import Foundation

/// The Safari extension sends only the selected page's public URL and title.
public struct BookmarkSaveRequest {
    public let pageURL: URL
    public let title: String?

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "bookmarker", url.host == "save",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawURL = parts.queryItems?.first(where: { $0.name == "url" })?.value,
              let pageURL = Bookmark.normalizedURL(rawURL) else { return nil }
        self.pageURL = pageURL
        title = parts.queryItems?.first(where: { $0.name == "title" })?.value.map { String($0.prefix(4096)) }
    }
}
