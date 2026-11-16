import BookmarkCore
import SwiftUI

struct BookmarkDetail: View {
    @Bindable var library: Library
    let bookmark: Bookmark
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    if let url = URL(string: bookmark.url) {
                        Link(bookmark.host.uppercased(), destination: url).font(.caption.weight(.medium)).tracking(1.3)
                            .foregroundStyle(.secondary).help(bookmark.url)
                    }
                    Spacer()
                }
                Text(bookmark.title).font(.system(size: 29, weight: .semibold, design: .serif)).textSelection(.enabled)
                if URL(string: bookmark.url) != nil {
                    WebpageReader(library: library, bookmark: bookmark).frame(height: 460)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                }
                BookmarkComments(library: library, bookmark: bookmark).id(bookmark.id)
                HStack(spacing: 8) {
                    Text("Saved \(bookmark.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    Text("·")
                    Text(bookmark.topics.first ?? "Inbox").lineLimit(1)
                }.font(.caption).foregroundStyle(.tertiary)
            }.padding(28).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
}

struct AddBookmark: View {
    let library: Library
    let onAdd: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var topics = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Keep something good.").font(.title2.weight(.semibold))
            Text("The article title will be fetched automatically.").foregroundStyle(.secondary)
            TextField("https://example.com/article", text: $url).textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit(add)
            TextField("Topic (optional — otherwise Inbox)", text: $topics).textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Bookmark", action: add).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(Bookmark.normalizedURL(url) == nil)
            }
        }.padding(28).frame(width: 450).onAppear { focused = true }
    }
    private func add() {
        if let id = library.add(url, topics: topics) {
            onAdd(id)
            dismiss()
        }
    }
}

struct EditBookmark: View {
    let library: Library
    let bookmark: Bookmark
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var topics: String
    init(library: Library, bookmark: Bookmark) {
        self.library = library
        self.bookmark = bookmark
        _title = State(initialValue: bookmark.title)
        _topics = State(initialValue: bookmark.topics.joined(separator: ", "))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit bookmark").font(.title2.weight(.semibold))
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            TextField("Topic (leave empty for Inbox)", text: $topics).textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    guard library.bookmarks.first(where: { $0.id == bookmark.id }) == bookmark else {
                        library.error =
                            "This bookmark changed while you were editing. Reopen the editor to use the latest version."
                        dismiss()
                        return
                    }
                    var updated = bookmark
                    updated.title = title
                    updated.topics = Library.topics(topics)
                    if library.save(updated, actionName: "Edit Bookmark") { dismiss() }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 460)
    }
}

struct BookmarkComments: View {
    let library: Library
    let bookmark: Bookmark
    @State private var draft: String
    @State private var saved: String
    @State private var conflict = false
    @State private var pendingSave: Task<Void, Never>?

    init(library: Library, bookmark: Bookmark) {
        self.library = library
        self.bookmark = bookmark
        _draft = State(initialValue: bookmark.notes)
        _saved = State(initialValue: bookmark.notes)
    }
    private func saveComments(_ value: String) async {
        guard !conflict else { return }
        guard var latest = library.bookmarks.first(where: { $0.id == bookmark.id }), latest.notes == saved else {
            conflict = true
            return
        }
        latest.notes = value
        if await library.saveInBackground(latest) { saved = value } else { conflict = true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("COMMENTS").font(.caption2.weight(.semibold)).tracking(1).foregroundStyle(.secondary)
            TextEditor(
                text: Binding(
                    get: { draft },
                    set: { value in
                        draft = value
                        let previous = pendingSave
                        pendingSave = Task { @MainActor in
                            await previous?.value
                            await saveComments(value)
                        }
                    })
            )
            .font(.body).scrollContentBackground(.hidden)
            .padding(8).frame(minHeight: 180)
            .background(.quinary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            .accessibilityLabel("Comments")
            .overlay(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("Add comment").font(.body).foregroundStyle(.tertiary)
                        .padding(.leading, 13).padding(.top, 8)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            if conflict {
                Text("Comments changed outside this editor. Copy your draft before reloading the saved comments.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reload saved comments") {
                    if let latest = library.bookmarks.first(where: { $0.id == bookmark.id }) {
                        saved = latest.notes
                        draft = latest.notes
                        conflict = false
                    }
                }
            }

        }
        .onChange(of: bookmark.notes) { _, newValue in
            if draft == saved {
                draft = newValue
                saved = newValue
            }
        }
    }
}

struct BookmarkStatusButtons: View {
    let library: Library
    let bookmark: Bookmark
    var body: some View {
        HStack(spacing: 12) {
            Button {
                library.update(bookmark.id) { $0.isFavorite.toggle() }
            } label: {
                Image(systemName: bookmark.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(bookmark.isFavorite ? Color.orange : Color.secondary)
            }
            .help(bookmark.isFavorite ? "Remove from Favorites" : "Add to Favorites")
            .accessibilityLabel(bookmark.isFavorite ? "Remove from Favorites" : "Add to Favorites")
            Button {
                library.update(bookmark.id) { $0.isRead.toggle() }
            } label: {
                Image(systemName: bookmark.isRead ? "checkmark.circle.fill" : "checkmark.circle")
                    .foregroundStyle(bookmark.isRead ? Color.accentColor : Color.secondary)
            }
            .help(bookmark.isRead ? "Mark as Unread" : "Mark as Read")
            .accessibilityLabel(bookmark.isRead ? "Mark as Unread" : "Mark as Read")
        }.buttonStyle(.borderless)
    }
}

struct SidebarCountRow: View {
    let title: String
    var symbol: String? = nil
    let count: Int
    var body: some View {
        HStack(spacing: 8) {
            if let symbol { Image(systemName: symbol) }
            Text(title).lineLimit(1)
            Spacer(minLength: 8)
            Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(count) items")
    }
}
