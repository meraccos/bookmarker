import SwiftUI
import BookmarkCore

struct BookmarkRow: View, Equatable {
    let library: Library
    let bookmark: Bookmark
    let isFetching: Bool

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.library === rhs.library && lhs.bookmark == rhs.bookmark && lhs.isFetching == rhs.isFetching
    }
    var body: some View {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 9) {
                                HStack {
                                    Text(bookmark.host).font(.caption).foregroundStyle(.secondary).help(bookmark.url)
                                    Spacer(minLength: 8)
                                    BookmarkStatusButtons(library: library, bookmark: bookmark)
                                    if isFetching { ProgressView().controlSize(.mini) }
                                }
                                Text(bookmark.title).font(.system(size: 15, weight: .medium)).lineLimit(2)
                                if let description = bookmark.pageDescription, !description.isEmpty {
                                    Text(description)
                                        .font(.system(size: 13)).foregroundStyle(.secondary)
                                        .lineLimit(2).truncationMode(.tail)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
    }
}
