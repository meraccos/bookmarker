import BookmarkCore
import SwiftUI

@main struct BookmarkerApp: App {
    @State private var library = Library()
    var body: some Scene {
        WindowGroup {
            LibraryView(library: library).frame(minWidth: 900, minHeight: 580)
                .task(id: library.folder) {
                    await library.prepareLibrary()
                    guard !Task.isCancelled else { return }
                    await library.migrateReadingCopies()
                    let folder = library.folder
                    for id in library.bookmarks.filter({
                        $0.title.isEmpty || $0.title == $0.host || $0.pageDescription == nil
                    }).map(\.id) {
                        guard !Task.isCancelled, library.folder == folder else { return }
                        await library.refresh(
                            id,
                            updateTitle: library.bookmarks.first(where: { $0.id == id }).map {
                                $0.title.isEmpty || $0.title == $0.host
                            } ?? false)
                    }
                }

                .task {
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(3600)) } catch { return }
                        await library.backUpIfNeeded()
                    }
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .textEditing) {
                Button("Search Bookmarks…") {
                    guard let toolbar = NSApp.keyWindow?.toolbar,
                        let search = toolbar.items.compactMap({ $0 as? NSSearchToolbarItem }).first
                    else { return }
                    search.beginSearchInteraction()
                }.keyboardShortcut("f")
            }
        }
        Settings { LibrarySettings(library: library) }
    }
}

struct LibraryView: View {
    @Bindable var library: Library
    @Environment(\.undoManager) private var undoManager
    @State private var bookmarkColumnTrailingX: CGFloat = 635
    @State private var toolbarLeadingX: CGFloat = 219
    @State private var selection: Set<UUID> = []
    @State private var filter = "All bookmarks"
    @State private var search = ""
    @AppStorage("bookmarkSortOrder") private var sortOrder: BookmarkSortOrder = .newestAdded
    @State private var unreadOnly = false
    @State private var editingBookmark: Bookmark?
    @State private var adding = false
    @State private var deleting = false
    @State private var movingBookmarks: Set<UUID> = []
    @State private var newTopic = ""
    @State private var renamingTopic: String?
    @State private var renamedTopic = ""
    @AppStorage("sidebarTopicOrder") private var sidebarTopicOrder = "[]"
    private var topics: [String] {
        let available = Set(library.bookmarks.flatMap(\.topics))
        let saved = (try? JSONDecoder().decode([String].self, from: Data(sidebarTopicOrder.utf8))) ?? []
        var ordered: [String] = []
        for topic in saved where available.contains(topic) && !ordered.contains(topic) {
            ordered.append(topic)
        }
        return ordered + available.subtracting(ordered).sorted()
    }
    private func moveTopics(from offsets: IndexSet, to destination: Int) {
        var ordered = topics
        ordered.move(fromOffsets: offsets, toOffset: destination)
        if let data = try? JSONEncoder().encode(ordered), let value = String(data: data, encoding: .utf8) {
            sidebarTopicOrder = value
        }
    }
    private var emptyListTitle: String {
        !search.isEmpty ? "No matching bookmarks" : (unreadOnly ? "No unread bookmarks" : "No bookmarks here yet")
    }
    private var emptyListDescription: String {
        !search.isEmpty
            ? "Try another search."
            : (unreadOnly
                ? "Turn off Unread to see all items in this section."
                : "Use the right-click menu to organize your bookmarks.")
    }
    private var visible: [Bookmark] {
        library.bookmarks.filter { item in
            (filter == "All bookmarks"
                || (filter == "Favorites"
                    ? item.isFavorite
                    : (filter == "Inbox" ? item.topics.isEmpty : item.topics.contains(String(filter.dropFirst(6))))))
                && (!unreadOnly || !item.isRead)
                && (search.isEmpty
                    || [
                        item.title, item.url, item.pageDescription ?? "", item.notes,
                        item.topics.joined(separator: " "), library.readingSearchText[item.id] ?? "",
                    ].joined(separator: " ").localizedCaseInsensitiveContains(search))
        }.sorted(by: sortOrder.precedes)
    }
    var body: some View {
        let visible = visible
        let selectedBookmark = visible.first(where: { selection.contains($0.id) })
        let summary = BookmarkSummary(library.bookmarks)
        let topics = topics
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Image(systemName: "bookmark.fill").foregroundStyle(.orange)
                    Text("Bookmarker").font(.title3.weight(.semibold))
                }.padding(20)
                List(selection: $filter) {
                    SidebarCountRow(title: "All bookmarks", symbol: "square.stack", count: library.bookmarks.count).tag(
                        "All bookmarks")
                    SidebarCountRow(title: "Favorites", symbol: "star", count: summary.favorites).tag("Favorites")
                        .modifier(BookmarkDropTarget(library: library, destination: .favorites))
                    SidebarCountRow(title: "Inbox", symbol: "tray", count: summary.inbox).tag("Inbox")
                        .modifier(BookmarkDropTarget(library: library, destination: .inbox))
                    Section("Topics") {
                        ForEach(topics, id: \.self) { topic in
                            SidebarCountRow(
                                title: topic, symbol: "number", count: summary.topicCounts[topic, default: 0]
                            )
                            .tag("topic:" + topic)
                            .modifier(BookmarkDropTarget(library: library, destination: .topic(topic)))
                            .contextMenu {
                                Button("Rename Topic…") {
                                    renamedTopic = topic
                                    renamingTopic = topic
                                }
                            }
                        }
                        .onMove(perform: moveTopics)
                    }
                }.listStyle(.sidebar)
                SidebarSyncStatus(library: library).padding(.horizontal, 20).padding(.vertical, 14)

            }.navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 280)
        } content: {
            listContent(visible).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .overlay(alignment: .top) { toolbarDivider }
                .background(WindowTitleHider(measuresTrailingEdge: true) { bookmarkColumnTrailingX = $0 })
                .navigationSplitViewColumnWidth(min: 300, ideal: 420, max: 600)
        } detail: {
            detailContent(selectedBookmark).frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) { toolbarDivider }
        }
        .onAppear { library.undoManager = undoManager }
        .onChange(of: visible.map(\.id)) { _, ids in selection.formIntersection(Set(ids)) }
        .onOpenURL { requestURL in
            guard let request = BookmarkSaveRequest(url: requestURL) else { return }
            Task {
                guard let id = await library.addFromSafari(request) else { return }
                // Reveal new and already-saved bookmarks regardless of the previous view.
                search = ""
                unreadOnly = false
                filter = "All bookmarks"
                selection = [id]
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .navigationTitle(" ")
        .disabled(library.isSettingUpCloud)
        .toolbarRole(.editor)
        .searchable(text: $search, placement: .toolbar, prompt: "Search your library")
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) {
                    listToolbarControls
                }.sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) { listToolbarControls }
            }
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) { readingToolbarControls(selectedBookmark) }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) { readingToolbarControls(selectedBookmark) }
            }
        }
        .sheet(item: $editingBookmark) { EditBookmark(library: library, bookmark: $0) }
        .alert(
            "Rename Topic",
            isPresented: Binding(
                get: { renamingTopic != nil },
                set: { if !$0 { renamingTopic = nil } }
            )
        ) {
            TextField("Topic name", text: $renamedTopic)
            Button("Rename", action: renameTopic)
                .disabled(renamedTopic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { renamingTopic = nil }
        } message: {
            Text("Every bookmark in this topic will use the new name.")
        }
        .sheet(isPresented: $adding) {
            AddBookmark(library: library) {
                filter = "All bookmarks"
                selection = [$0]
            }
        }
        .alert(
            "Library needs attention",
            isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })
        ) {
            Button("OK") { library.error = nil }
        } message: {
            Text(library.error ?? "")
        }
        .alert(
            "Move to a new topic",
            isPresented: Binding(get: { !movingBookmarks.isEmpty }, set: { if !$0 { movingBookmarks.removeAll() } })
        ) {
            TextField("Topic name", text: $newTopic)
            Button("Move") {
                library.update(movingBookmarks, actionName: "Move Bookmarks") { $0.move(to: newTopic) }
                movingBookmarks.removeAll()
            }.disabled(newTopic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { movingBookmarks.removeAll() }
        } message: {
            Text("The selected bookmarks will move to the new topic.")
        }
        .confirmationDialog(
            "Move \(selection.count == 1 ? "this bookmark" : "these \(selection.count) bookmarks") to the Trash?",
            isPresented: $deleting, titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive, action: deleteSelection)
        }
    }
    private func deleteSelection() {
        selection.subtract(library.remove(selection))
    }
    private func renameTopic() {
        guard let original = renamingTopic else { return }
        let name = renamedTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        let ordered = topics.map { $0 == original ? name : $0 }
        guard library.renameTopic(original, to: name) else { return }
        if let data = try? JSONEncoder().encode(ordered), let value = String(data: data, encoding: .utf8) {
            sidebarTopicOrder = value
        }
        if filter == "topic:" + original { filter = "topic:" + name }
        renamingTopic = nil
    }
    @ViewBuilder private func detailContent(_ selectedBookmark: Bookmark?) -> some View {
        if selection.count == 1, let bookmark = selectedBookmark {
            BookmarkDetail(library: library, bookmark: bookmark)
        } else if selection.count > 1 {
            ContentUnavailableView(
                "\(selection.count) bookmarks selected", systemImage: "square.stack",
                description: Text("Drag to a topic, or right-click to move, mark, or delete the selected bookmarks."))
        } else {
            ContentUnavailableView(
                "Room for another idea", systemImage: "text.book.closed",
                description: Text("Select a bookmark to organize it and add comments."))
        }
    }
    @ViewBuilder private func listContent(_ visible: [Bookmark]) -> some View {
        if library.bookmarks.isEmpty && library.pendingCloudBookmarks > 0 {
            ContentUnavailableView(
                "Downloading bookmark details", systemImage: "icloud.and.arrow.down",
                description: Text(
                    "Found \(library.pendingCloudBookmarks) bookmarks in iCloud. They will appear as their details become available."
                ))
        } else if library.bookmarks.isEmpty {
            ContentUnavailableView {
                Label("A little space for good reads", systemImage: "bookmark")
            } description: {
                Text("Save a link. Keep the ideas worth returning to.")
            } actions: {
                Button("Add your first bookmark") { adding = true }.buttonStyle(.borderedProminent)
            }
        } else if visible.isEmpty {
            ContentUnavailableView {
                Label(emptyListTitle, systemImage: search.isEmpty ? "tray" : "magnifyingglass")
            } description: {
                Text(emptyListDescription)
            }
        } else {
            List(visible, selection: $selection) { bookmark in
                BookmarkRow(library: library, bookmark: bookmark, isFetching: library.fetching.contains(bookmark.id))
                    .equatable()
                    .padding(.horizontal, 12).padding(.vertical, 14)
                    .contentShape(Rectangle())
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            if library.remove(bookmark.id) { selection.remove(bookmark.id) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            library.update(bookmark.id) { $0.isRead.toggle() }
                        } label: {
                            Label(
                                bookmark.isRead ? "Unread" : "Read",
                                systemImage: bookmark.isRead ? "envelope.badge" : "envelope.open")
                        }.tint(.blue)
                    }
                    .onDrag {
                        if !selection.contains(bookmark.id) { selection = [bookmark.id] }
                        let identifiers = selection.map { id in id.uuidString }
                        return NSItemProvider(object: identifiers.sorted().joined(separator: "\n") as NSString)
                    }
                    .tag(bookmark.id)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.visible)
                    .listRowBackground(Color.clear)
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                bookmarkActions(for: ids)
            } primaryAction: { _ in
                // Double-click and Return keep the reading view in the app.
            }
            .listStyle(.inset)
            .onDeleteCommand(perform: deleteSelection)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
    @ViewBuilder private func bookmarkActions(for ids: Set<UUID>) -> some View {
        let items = library.bookmarks.filter { ids.contains($0.id) }
        if !items.isEmpty {
            if items.count == 1, let bookmark = items.first {
                Button("Open in Browser") { open(bookmark) }
                Button("Edit Bookmark…") { editingBookmark = bookmark }
            }
            Divider()
            let allFavorite = items.allSatisfy(\.isFavorite)
            let allRead = items.allSatisfy(\.isRead)
            Button(allFavorite ? "Remove from Favorites" : "Add to Favorites") {
                library.update(ids, actionName: "Change Favorites") { $0.isFavorite = !allFavorite }
            }
            Button(allRead ? "Mark as Unread" : "Mark as Read") {
                library.update(ids, actionName: "Change Read Status") { $0.isRead = !allRead }
            }
            Menu("Move to") {
                Button("Inbox") { library.update(ids, actionName: "Move Bookmarks") { $0.move(to: nil) } }
                ForEach(topics, id: \.self) { topic in
                    Button(topic) { library.update(ids, actionName: "Move Bookmarks") { $0.move(to: topic) } }
                }
                Divider()
                Button("New Topic…") {
                    newTopic = ""
                    movingBookmarks = ids
                }
            }
            Divider()
            Button("Refresh Website Details") { Task { for id in ids { await library.refresh(id) } } }
            Button("Move to Trash", role: .destructive) {
                selection = ids
                deleting = true
            }
        }
    }
    private var toolbarDivider: some View {
        Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.65))
            .frame(height: 0.5).allowsHitTesting(false).accessibilityHidden(true)
    }
    private func readingToolbarControls(_ selectedBookmark: Bookmark?) -> some View {
        HStack(spacing: 6) {
            if let bookmark = selectedBookmark {
                Button {
                    open(bookmark)
                } label: {
                    Label("Read original", systemImage: "arrow.up.right.square")
                        .frame(width: 36, height: 34).contentShape(Rectangle())
                }
                .help("Read original in browser").disabled(selection.count != 1)
                Menu {
                    bookmarkActions(for: selection)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 20, weight: .medium))
                        .frame(width: 36, height: 34).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Bookmark actions")
                if selection.count == 1 {
                    let minutes = bookmark.readingMinutes
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: 1, height: 18)
                        .padding(.horizontal, 6)
                        .accessibilityHidden(true)
                    Text(minutes.map { "\($0) mins" } ?? "— mins")
                        .font(.system(size: 15, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .padding(.trailing, 12)
                        .help("Estimated reading time at 200 words per minute")
                        .accessibilityLabel(
                            minutes.map { "Estimated reading time: \($0) minutes" } ?? "Reading time unavailable")
                }
            } else {
                Button {
                } label: {
                    Label("Read original", systemImage: "arrow.up.right.square")
                }.disabled(true)
                Button {
                } label: {
                    Label("Bookmark actions", systemImage: "ellipsis")
                }.disabled(true)
            }
        }
        .font(.system(size: 20)).labelStyle(.iconOnly).buttonStyle(.plain)
        .padding(.horizontal, 6).frame(height: 34)
        .background(.regularMaterial, in: Capsule())
        .padding(.leading, 24)
    }
    private var listToolbarControls: some View {
        HStack(spacing: 0) {
            Text(filter.hasPrefix("topic:") ? String(filter.dropFirst(6)) : filter).font(.headline).lineLimit(1)
                .padding(.leading, 18)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Menu {
                    Picker("Sort Bookmarks", selection: $sortOrder) {
                        ForEach(BookmarkSortOrder.allCases) { order in Text(order.label).tag(order) }
                    }.pickerStyle(.inline)
                } label: {
                    Image(systemName: "arrow.up.arrow.down").font(.system(size: 20))
                        .frame(width: 36, height: 34).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Sort Bookmarks").help("Sort bookmarks")
                Toggle(isOn: $unreadOnly) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 22))
                        .frame(width: 36, height: 34).contentShape(Rectangle())
                        .foregroundStyle(unreadOnly ? Color.accentColor : Color.secondary)
                }
                .toggleStyle(.button).buttonStyle(.plain)
                .accessibilityLabel("Unread filter")
                .help(unreadOnly ? "Show all bookmarks" : "Show only unread bookmarks")
                Button {
                    adding = true
                } label: {
                    Image(systemName: "plus").font(.system(size: 20))
                        .frame(width: 36, height: 34).contentShape(Rectangle())
                }
                .buttonStyle(.plain).keyboardShortcut("n")
                .accessibilityLabel("Add Bookmark").help("Add bookmark (⌘N)")
            }
            .padding(.horizontal, 6).frame(height: 34)
            .background(.regularMaterial, in: Capsule())
        }
        .frame(width: max(120, bookmarkColumnTrailingX - toolbarLeadingX - 12), height: 38)
        .background(WindowTitleHider { toolbarLeadingX = $0 })

    }
    private func open(_ bookmark: Bookmark) { if let url = URL(string: bookmark.url) { NSWorkspace.shared.open(url) } }
}

private struct BookmarkDropTarget: ViewModifier {
    enum Destination {
        case inbox, favorites
        case topic(String)
        var actionName: String {
            switch self {
            case .favorites: "Add to Favorites"
            case .inbox, .topic: "Move Bookmark"
            }
        }
    }
    let library: Library
    let destination: Destination
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .background(targeted ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .dropDestination(for: String.self) { values, _ in
                let ids = Set(values.flatMap { $0.split(separator: "\n") }.compactMap { UUID(uuidString: String($0)) })
                    .filter { id in library.bookmarks.contains(where: { $0.id == id }) }
                guard !ids.isEmpty else { return false }
                library.update(ids, actionName: destination.actionName) { bookmark in
                    switch destination {
                    case .inbox: bookmark.move(to: nil)
                    case .favorites: bookmark.isFavorite = true
                    case .topic(let name): bookmark.move(to: name)
                    }
                }
                return true
            } isTargeted: {
                targeted = $0
            }
    }
}

private struct SidebarSyncStatus: View {
    let library: Library
    private var presentation: (title: String, symbol: String, color: Color, help: String) {
        if library.isSettingUpCloud {
            return (
                "Setting up iCloud…", "icloud", .secondary,
                "Copying bookmark entries into iCloud Drive. Reading copies stay on this Mac."
            )
        }
        if library.pendingCloudBookmarks > 0 {
            return (
                "\(library.pendingCloudBookmarks) bookmarks downloading…", "icloud.and.arrow.down", .secondary,
                "Available bookmarks are ready to use. Remaining bookmark details will appear as iCloud downloads them."
            )
        }
        switch library.syncStatus.state {
        case .checking:
            return ("Checking iCloud…", "icloud", .secondary, "Checking the library’s iCloud upload status.")
        case .local:
            return (
                "Stored on this Mac", "internaldrive", .secondary,
                "This library is outside iCloud Drive. Choose an iCloud Drive library folder in Bookmarker Settings to sync between Macs."
            )
        case .syncing:
            return (
                "Syncing with iCloud…", "arrow.triangle.2.circlepath.icloud", .secondary,
                "Some library files are waiting to upload or are transferring. Keep this Mac awake and online until uploads finish."
            )
        case .uploaded:
            return (
                "Uploaded to iCloud", "checkmark.circle.fill", .green,
                "iCloud reports the current library files are uploaded. Another Mac may still need to download them. This is not a system shutdown guarantee."
            )
        case .problem(let detail): return ("Sync needs attention", "exclamationmark.icloud", .orange, detail)
        }
    }
    var body: some View {
        let status = presentation
        HStack(spacing: 8) {
            Image(systemName: status.symbol).foregroundStyle(status.color)
            Text(status.title).foregroundStyle(.secondary).lineLimit(2)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(status.help)
        .accessibilityElement(children: .combine)
        .accessibilityHint(status.help)
    }
}
