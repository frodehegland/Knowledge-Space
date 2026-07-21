import SwiftUI
import Observation

/// App-wide state: the library folder and its index, plus reader
/// navigation. The folder choice persists across launches as a
/// security-scoped bookmark.
@MainActor @Observable
final class AppState {
    let index = LibraryIndex()

    /// The document open in the reader.
    var selectedDocID: String?
    /// A paragraph to scroll to and flash, on arrival by fragment link.
    var pendingFragment: String?
    /// Superseded documents are hidden by default; history stays reachable.
    var showsSuperseded = false

    private static let bookmarkKey = "libraryFolderBookmark"

    init() {
        restoreFolder()
    }

    var selectedDoc: LiquidDoc? {
        selectedDocID.flatMap { index.byID[$0]?.doc }
    }

    /// Entries as listed: newest first, superseded hidden unless shown.
    var listedEntries: [IndexEntry] {
        index.timeline.reversed().filter { entry in
            showsSuperseded || !index.supersededIDs.contains(entry.id)
        }
    }

    func chooseFolder(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        saveBookmark(url)
        index.setFolder(url)
    }

    /// Opens an `origamitext://open/<id>#<fragment>` link. Per the format,
    /// every link except `revises` follows through to the latest revision.
    func open(url: URL) {
        guard url.scheme?.lowercased() == "origamitext" else { return }
        let id = LiquidAddress.canonical(url.host() ?? url.lastPathComponent)
        open(id: id, fragment: url.fragment)
    }

    func open(id: String, fragment: String? = nil) {
        let target = index.latestRevision(of: id)
        guard index.byID[target] != nil else { return }
        selectedDocID = target
        // Paragraph ids are only trustworthy in the document they were
        // written against; a revision may have renumbered them.
        pendingFragment = target == id ? fragment : nil
    }

    // MARK: - Folder persistence

    private func saveBookmark(_ url: URL) {
        #if os(macOS)
        let data = try? url.bookmarkData(options: .withSecurityScope,
                                         includingResourceValuesForKeys: nil,
                                         relativeTo: nil)
        #else
        let data = try? url.bookmarkData()
        #endif
        UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
    }

    private func restoreFolder() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var isStale = false
        #if os(macOS)
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: .withSecurityScope,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &isStale) else { return }
        #else
        guard let url = try? URL(resolvingBookmarkData: data,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &isStale) else { return }
        #endif
        _ = url.startAccessingSecurityScopedResource()
        if isStale { saveBookmark(url) }
        index.setFolder(url)
    }
}
