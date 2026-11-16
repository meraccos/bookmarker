import BookmarkCore
import SwiftUI

struct LibrarySettings: View {
    @Bindable var library: Library
    var body: some View {
        Form {
            Section("Library") {
                Text(library.folder.path).font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Choose Library Folder…") { library.chooseFolder() }
                    Button("Show in Finder") { NSWorkspace.shared.open(library.folder) }
                }
                Button(library.isSettingUpCloud ? "Setting up iCloud…" : "Use Automatic iCloud Library") {
                    Task { await library.useAutomaticCloudLibrary() }
                }.disabled(library.isSettingUpCloud || library.backupInProgress)
                if let message = library.cloudSetupMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                Text(
                    "The automatic library uses iCloud Drive/Bookmarker/Library on each Mac. Existing bookmarks are copied safely; the original library is kept. Choosing another folder switches libraries without copying."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Backups") {
                if let date = library.lastBackupDate {
                    Text("Last backup: \(date.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(
                        .secondary)
                }
                HStack {
                    Button(library.backupInProgress ? "Backing up…" : "Back Up Now") {
                        Task { await library.backUpIfNeeded(force: true) }
                    }
                    .disabled(library.backupInProgress || library.isSettingUpCloud)
                    Button("Show Backups") {
                        try? FileManager.default.createDirectory(
                            at: library.backupsFolder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(library.backupsFolder)
                    }
                }
                Text(
                    "Seven daily snapshots are kept on this Mac, including comments, topics, and read/favorite state. Reading copies are not duplicated. Each snapshot includes recovery instructions."
                )
                .font(.caption).foregroundStyle(.secondary)
                if let error = library.backupError { Text(error).font(.caption).foregroundStyle(.orange) }
            }
            Section("Offline reading") {
                Button("Show Local Reading Copies") {
                    try? FileManager.default.createDirectory(
                        at: library.readingCopiesFolder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(library.readingCopiesFolder)
                }
                Text(
                    "\(library.readingCopyCount) saved copies · \(ByteCountFormatter.string(fromByteCount: library.readingCopyBytes, countStyle: .file))"
                )
                .foregroundStyle(.secondary)
                if library.downloadProgress.running {
                    ProgressView(
                        value: Double(library.downloadProgress.completed),
                        total: Double(max(1, library.downloadProgress.total))
                    ) {
                        Text("\(library.downloadProgress.completed) of \(library.downloadProgress.total) checked")
                    }
                    Button("Cancel Downloads") { library.cancelReadingDownloads() }
                } else {
                    Button("Download All Missing Copies") { library.downloadAllReadingCopies() }
                    if library.downloadProgress.completed > 0 {
                        Text(
                            "\(library.downloadProgress.completed - library.downloadProgress.failed) available · \(library.downloadProgress.failed) unavailable"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(
                    "Reading copies are stored locally on this Mac, outside iCloud. Each Mac downloads its own copies. Websites that block reading access may be skipped."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding(12).frame(width: 500, height: 650)
            .task(id: library.folder) { await library.refreshReadingCopyStats() }
    }
}
