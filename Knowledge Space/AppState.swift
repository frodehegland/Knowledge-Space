import SwiftUI
import Observation
#if canImport(AppKit)
import AppKit
#endif

/// App-wide state: the library folder and its index, plus reader
/// navigation. The folder choice persists across launches as a
/// security-scoped bookmark.
@MainActor @Observable
final class AppState {
    let index = LibraryIndex()
    /// Every place the notes have carried, searched once and remembered.
    let places = PlaceDirectory()
    /// The place this machine last resolved — attached to a new note at
    /// creation, per the format: a place name, never coordinates. Stays
    /// nil until macOS grants location, and the note travels without.
    private(set) var currentPlace: String?
    private let placeFinder = PlaceFinder()

    /// The document open in the reader. Opening a note is reading it —
    /// its bolding in the list ends here; Mark Unread restores it.
    var selectedDocID: String? {
        didSet {
            if let selectedDocID { markRead(selectedDocID) }
        }
    }
    /// A paragraph to scroll to and flash, on arrival by fragment link.
    var pendingFragment: String?
    /// Superseded documents are hidden by default; history stays reachable.
    var showsSuperseded = false

    // MARK: - View-module state (see LibraryViewModule.swift)

    /// The sidebar place being shown: the document library, or a view module.
    var sidebarSelection: SidebarItem? = .library
    /// Filters the document list and the insight views' rows.
    var searchText = ""
    /// A transient status message, shown briefly at the window's bottom.
    private(set) var transientNote: String?
    private var noteToken = UUID()
    /// A second document being read side by side with the selected one.
    private(set) var parallelDoc: LiquidDoc?
    /// Sidebar views switched off in Edit Views, by module id. The module
    /// stays installed — it just leaves the sidebar.
    private(set) var hiddenViewIDs: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "hiddenViewIDs") ?? [])

    private static let bookmarkKey = "libraryFolderBookmark"

    init() {
        restoreFolder()
        placeFinder.onPlace = { [weak self] place in
            self?.currentPlace = place
        }
        placeFinder.begin()
        // "To Do" is a standing filing folder: filing a note there marks
        // it to do, and the sidebar's To Do place lists exactly those.
        if !filingFolders.contains(where: { $0.caseInsensitiveCompare("To Do") == .orderedSame }) {
            filingFolders.insert("To Do", at: 0)
            UserDefaults.standard.set(filingFolders, forKey: "filingFolders")
        }
    }

    // MARK: - Parallel reading, view curation, and notes
    // (Mutators live here beside their private(set) storage; the rest of
    // the view-module API is in Views/AppStateLibrary.swift.)

    func enterParallel(with doc: LiquidDoc) {
        parallelDoc = doc
    }

    func exitParallel() {
        parallelDoc = nil
    }

    func setView(_ id: String, hidden: Bool) {
        if hidden {
            hiddenViewIDs.insert(id)
            // The view being read leaves the sidebar: land somewhere real.
            if sidebarSelection == .view(id) { sidebarSelection = .library }
        } else {
            hiddenViewIDs.remove(id)
        }
        UserDefaults.standard.set(Array(hiddenViewIDs), forKey: "hiddenViewIDs")
    }

    /// A transient status message, shown briefly at the window's bottom.
    func showNote(_ text: String) {
        let token = UUID()
        noteToken = token
        transientNote = text
        Task {
            try? await Task.sleep(for: .seconds(3))
            if noteToken == token { transientNote = nil }
        }
    }

    var selectedDoc: LiquidDoc? {
        selectedDocID.flatMap { index.byID[$0]?.doc }
    }

    /// The span of days the Timeline shows, chosen from its calendar —
    /// nil shows everything. The label is what the calendar button
    /// reads: "2026", "July 2026", "22 July 2026".
    private(set) var timelineRange: ClosedRange<Date>?
    private(set) var timelineRangeLabel: String?

    func setTimelineRange(_ range: ClosedRange<Date>?, label: String? = nil) {
        timelineRange = range
        timelineRangeLabel = range == nil ? nil : label
    }

    /// Entries as listed: newest first, superseded hidden unless shown,
    /// muted people's documents left out entirely, documents filed
    /// under Archived living in the Filed list alone, drafts living
    /// under Drafts alone, and only the Timeline calendar's chosen span
    /// when one is set. Identity cards are contact records, not
    /// correspondence — they live in Settings ▸ Author, never in the
    /// document lists.
    var listedEntries: [IndexEntry] {
        index.timeline.reversed().filter { entry in
            guard !isMuted(entry.doc.author), !isArchived(entry.doc), !isDraft(entry.doc),
                  entry.doc.documentType != IdentityCard.documentType else { return false }
            if let timelineRange, !timelineRange.contains(entry.doc.listedDate) { return false }
            return showsSuperseded || !index.supersededIDs.contains(entry.id)
        }
    }

    // MARK: - Read state

    /// Documents the reader has opened, by id. The complement is "unread",
    /// bold in the list. Persisted across launches.
    private(set) var readDocumentIDs: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "readDocumentIDs") ?? [])

    func isUnread(_ doc: LiquidDoc) -> Bool {
        !readDocumentIDs.contains(doc.id)
    }

    func markRead(_ id: String) {
        guard readDocumentIDs.insert(id).inserted else { return }
        persistReadIDs()
    }

    /// The reader's "put it back": the note stays unread — and bold —
    /// until it is opened again.
    func markUnread(_ doc: LiquidDoc) {
        guard readDocumentIDs.remove(doc.id) != nil else { return }
        persistReadIDs()
    }

    private func persistReadIDs() {
        UserDefaults.standard.set(Array(readDocumentIDs), forKey: "readDocumentIDs")
    }

    // MARK: - Drafts

    /// Drafts marked before the flag moved into the file itself — kept
    /// so those notes stay drafts; publishing clears the entry. New
    /// drafts carry `draft` in the document instead, so a note captured
    /// on the phone stays a draft here too.
    private(set) var draftDocumentIDs: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "draftDocumentIDs") ?? [])

    func isDraft(_ doc: LiquidDoc) -> Bool {
        doc.draft || draftDocumentIDs.contains(doc.id)
    }

    /// Flips the note's draft flag in the file, so every device sharing
    /// the folder agrees; the legacy local mark clears on publish.
    func setDraft(_ isDraft: Bool, for doc: LiquidDoc) {
        if !isDraft, draftDocumentIDs.remove(doc.id) != nil {
            persistDraftIDs()
        }
        guard doc.draft != isDraft else { return }
        var updated = doc
        updated.draft = isDraft
        do {
            try updated.jsonData().write(to: updated.fileURL, options: .atomic)
            index.rescan()
        } catch {
            showNote("Could not update the note: \(error.localizedDescription)")
        }
    }

    private func persistDraftIDs() {
        UserDefaults.standard.set(Array(draftDocumentIDs), forKey: "draftDocumentIDs")
    }

    // MARK: - Filing (the system shared with Origami Text)

    /// The one folder with special meaning: a document filed here leaves
    /// the library's lists. Every other folder is just a place — its
    /// documents stay visible everywhere.
    static let archivedFolderName = "Archived"

    /// Where documents are filed: id → folder name. Filing is a private
    /// judgement, persisted like read state — the files themselves never
    /// move, the community folder being shared.
    private(set) var filedFolders: [String: String] =
        UserDefaults.standard.dictionary(forKey: "filedFolders") as? [String: String] ?? [:]

    /// The folders offered for filing, user-extendable through New…;
    /// Archived stays last.
    private(set) var filingFolders: [String] =
        UserDefaults.standard.stringArray(forKey: "filingFolders")
            ?? ["Work", "Personal", "Archived"]

    func folder(for doc: LiquidDoc) -> String? {
        filedFolders[doc.id]
    }

    /// The filing folders that hold something, in their offered order,
    /// then any folder that exists only in the filings — the sidebar's
    /// Filed section, one place per folder.
    var filedFoldersInUse: [String] {
        let used = Set(filedFolders.values)
        var folders = filingFolders.filter(used.contains)
        folders += used.subtracting(folders).sorted()
        return folders
    }

    func isArchived(_ doc: LiquidDoc) -> Bool {
        filedFolders[doc.id] == Self.archivedFolderName
    }

    func fileDocument(_ doc: LiquidDoc, under folder: String) {
        filedFolders[doc.id] = folder
        persistFiling()
    }

    func unfile(_ doc: LiquidDoc) {
        guard filedFolders.removeValue(forKey: doc.id) != nil else { return }
        persistFiling()
    }

    /// A new folder joins just above Archived, which keeps the last word.
    func addFilingFolder(_ name: String) {
        guard !filingFolders.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
        else { return }
        let index = filingFolders.firstIndex(of: Self.archivedFolderName) ?? filingFolders.endIndex
        filingFolders.insert(name, at: index)
        UserDefaults.standard.set(filingFolders, forKey: "filingFolders")
    }

    #if os(macOS)
    /// Asks for a new folder's name and files the document there.
    func fileInNewFolder(_ doc: LiquidDoc) {
        let alert = NSAlert()
        alert.messageText = "New Folder"
        alert.informativeText = "Name the folder to file “\(doc.title)” under."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "File")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        addFilingFolder(name)
        // Filing under the offered spelling, when the name already
        // existed in another case.
        let folder = filingFolders.first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? name
        fileDocument(doc, under: folder)
    }
    #endif

    private func persistFiling() {
        UserDefaults.standard.set(filedFolders, forKey: "filedFolders")
    }

    #if os(macOS)
    /// Converts pre-rename `.origamitext` documents back into the library.
    /// The JSON inside is identical, so conversion is validation plus a
    /// rename: each file is decoded to prove it is a document, then written
    /// byte-for-byte into the library folder as `.liquid.json` — id,
    /// dates, links, and appendix all kept. A folder converts every old
    /// file it holds, recursively.
    func importLegacyDocuments() {
        guard let folderURL = index.folderURL else {
            showNote("Choose a library folder first — converted documents live there.")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose an old document (.origamitext), or a folder of them — each converts to .liquid.json in the library folder."
        panel.prompt = "Convert"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var files: [URL] = []
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                for case let candidate as URL in enumerator
                where LiquidDoc.isLegacyDocumentFile(candidate) {
                    files.append(candidate)
                }
            }
        } else if LiquidDoc.isLegacyDocumentFile(url) {
            files = [url]
        }
        guard !files.isEmpty else {
            showNote("No old documents (.origamitext) found there.")
            return
        }
        var converted = 0
        var skipped = 0
        var lastError: String?
        for file in files {
            do {
                let data = try Data(contentsOf: file)
                let doc = try LiquidDoc.decode(data: data, fileURL: file)
                // Something here already answers to this address — the
                // document is home; leave both copies untouched.
                if index.byID[doc.id] != nil { skipped += 1; continue }
                let stem = file.deletingPathExtension().lastPathComponent
                let destination = folderURL.appendingPathComponent(stem)
                    .appendingPathExtension(LiquidDoc.fileExtension)
                if FileManager.default.fileExists(atPath: destination.path) {
                    skipped += 1
                    continue
                }
                try data.write(to: destination)
                converted += 1
            } catch {
                lastError = error.localizedDescription
            }
        }
        index.rescan()
        var parts: [String] = []
        if converted > 0 { parts.append("converted \(converted) to .liquid.json") }
        if skipped > 0 { parts.append("\(skipped) already in the library") }
        if let lastError { parts.append("some failed: \(lastError)") }
        if parts.isEmpty { parts.append("nothing to convert") }
        showNote("Old documents: " + parts.joined(separator: " · "))
    }
    #endif

    /// A new note on the desk: an ordinary note document in the library
    /// folder, opened straight into writing.
    func newNote() {
        guard let folderURL = index.folderURL else {
            showNote("Choose a library folder first — notes live there.")
            return
        }
        let created = Date.now
        let id = LiquidAddress.makeID(author: authorName, created: created) { candidate in
            self.index.byID[candidate] != nil
        }
        // A new note starts as a draft — on the desk, out of the Inbox
        // and the views until its Draft toggle is switched off. The
        // flag travels in the file, so other devices agree.
        let doc = LiquidDoc(format: LiquidDoc.knownFormat,
                            id: id,
                            title: "Untitled",
                            author: authorName,
                            created: created,
                            body: [],
                            links: [],
                            wraps: nil,
                            draft: true,
                            documentType: LiquidDoc.DocumentType.note.rawValue,
                            location: currentPlace,
                            fileURL: folderURL.appendingPathComponent(id)
                                .appendingPathExtension(LiquidDoc.fileExtension))
        // A laptop moves between notes — refresh the place for the next.
        placeFinder.begin()
        do {
            try doc.jsonData().write(to: doc.fileURL, options: .atomic)
        } catch {
            showNote("Could not create the note: \(error.localizedDescription)")
            return
        }
        index.rescan()
        sidebarSelection = .drafts
        selectedDocID = id
    }

    // MARK: - The standing notes

    /// "To Do" and "Done" stand at the top of the list — ordinary note
    /// documents in the community folder, created once when the library
    /// doesn't hold them yet.
    private var ensuredStandingNotes = false

    func ensureStandingNotes() {
        guard !ensuredStandingNotes, let folderURL = index.folderURL,
              !index.isScanning else { return }
        let standing = [("To Do", "Add tasks here."),
                        ("Done", "Move finished tasks here.")]
        let existing = Set(index.byID.values.map {
            $0.doc.title.trimmingCharacters(in: .whitespaces).lowercased()
        })
        let missing = standing.filter { !existing.contains($0.0.lowercased()) }
        ensuredStandingNotes = true
        guard !missing.isEmpty else { return }
        for (offset, (title, starter)) in missing.enumerated() {
            // Distinct creation instants keep the derived ids distinct.
            let created = Date.now.addingTimeInterval(TimeInterval(offset))
            let id = LiquidAddress.makeID(author: authorName, created: created) { candidate in
                self.index.byID[candidate] != nil
            }
            let doc = LiquidDoc(format: LiquidDoc.knownFormat,
                                id: id,
                                title: title,
                                author: authorName,
                                created: created,
                                body: [LiquidDoc.Paragraph(id: "p1", heading: nil, text: starter)],
                                links: [],
                                wraps: nil,
                                documentType: LiquidDoc.DocumentType.note.rawValue,
                                fileURL: folderURL.appendingPathComponent(id)
                                    .appendingPathExtension(LiquidDoc.fileExtension))
            do {
                try doc.jsonData().write(to: doc.fileURL, options: .atomic)
            } catch {
                showNote("Could not create “\(title)”: \(error.localizedDescription)")
            }
        }
        index.rescan()
    }

    /// People whose documents are hidden from the library lists. The files
    /// themselves are untouched.
    var mutedAuthors: [String] = UserDefaults.standard.stringArray(forKey: "mutedAuthors") ?? [] {
        didSet { UserDefaults.standard.set(mutedAuthors, forKey: "mutedAuthors") }
    }

    func isMuted(_ author: String) -> Bool {
        let trimmed = author.trimmingCharacters(in: .whitespaces)
        return mutedAuthors.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// True when the restored folder can be read but not written — a
    /// bookmark minted while the app's permission was read-only. Only a
    /// fresh pick can renew it; ContentView opens the picker on this.
    private(set) var folderNeedsRepick = false

    func chooseFolder(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        saveBookmark(url)
        index.setFolder(url)
        folderNeedsRepick = false
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
        parallelDoc = nil   // navigation leaves parallel reading
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
        folderNeedsRepick = !FileManager.default.isWritableFile(atPath: url.path)
    }
}
