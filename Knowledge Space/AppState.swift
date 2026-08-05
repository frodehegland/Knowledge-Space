import SwiftUI
import Observation
#if canImport(AppKit)
import AppKit
#endif

/// Where a clicked note opens, chosen in Settings ▸ Appearance. The
/// default is the list itself: the row grows to hold all the words —
/// still the writing page, click and type — with the controls standing
/// on the window's right. The other layouts open the note in its own
/// pane, controls beside or under it. Documents that read rather than
/// write (articles, transcripts…) always open in their own pane.
enum NoteLayout: String, CaseIterable, Identifiable {
    case inList
    case controlsBeside
    case controlsUnder

    var id: String { rawValue }

    var label: String {
        switch self {
        case .inList: "In the list"
        case .controlsBeside: "Own pane, controls beside"
        case .controlsUnder: "Own pane, controls under"
        }
    }
}

/// App-wide state: the library folder and its index, plus reader
/// navigation. The folder choice persists across launches as a
/// security-scoped bookmark.
@MainActor @Observable
final class AppState {
    let index = LibraryIndex()
    /// Every place the notes have carried, searched once and remembered.
    let places = PlaceDirectory()
    /// The community's contact records — the same People.json Digital
    /// Letters and the phone read and write in the shared folder.
    let people = PersonDirectory()
    /// The named-locality registry the phone publishes into the folder —
    /// read-only here; the Mac refers to nicknames but does not add them.
    let localities = LocalityDirectory()
    #if os(macOS)
    /// The portrait pipeline carried over from Digital Letters: photos
    /// kept untouched, cartoons drawn by Image Playground.
    let portraits = PersonPortraitStore()
    #endif
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
            if oldValue != selectedDocID {
                flowReading = false
                showsVisualMeta = false
            }
        }
    }
    /// Whether the note page shows its Visual-Meta under the words —
    /// the appendix the file carries, or the block derived from its
    /// fields. Hidden by default; the Metadata button at every
    /// document's foot reveals it, per reading.
    var showsVisualMeta = false
    /// Flow, the reading aid carried over from Digital Letters: while
    /// on, dense prose is broken open for reading — sentences on their
    /// own lines, clauses after commas, parentheses apart. Display
    /// only, never written into the document; it turns off when the
    /// reading moves to another note.
    var flowReading = false
    /// A paragraph to scroll to and flash, on arrival by fragment link.
    var pendingFragment: String?
    /// Superseded documents are hidden by default; history stays reachable.
    var showsSuperseded = false
    /// The window's appearance — Gentle greys or High Contrast — chosen
    /// in Settings ▸ Appearance; the window rebuilds when it changes.
    var theme: AppTheme = AppTheme.current {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: AppTheme.key) }
    }
    /// How much of the sidebar shows — Small (the pared-down default) or
    /// Full — chosen in Settings ▸ Appearance; the column rebuilds when
    /// it changes.
    var sidebarLayout: SidebarLayout = SidebarLayout.current {
        didSet { UserDefaults.standard.set(sidebarLayout.rawValue, forKey: SidebarLayout.key) }
    }
    /// Whether the window currently stands as the two-column "In the
    /// list" arrangement: documents open in the list itself and no
    /// third pane exists. A module's canvas, the People place, and
    /// parallel reading still bring their own pane.
    var notesOpenInList: Bool {
        if case .sourceShelf = sidebarSelection { return false }
        return noteLayout == .inList
            && parallelDoc == nil
            && sidebarSelection != .people
            && LibraryViewRegistry.module(for: sidebarSelection) == nil
    }

    /// The point size of the notes list's rows in the "In the list"
    /// arrangement — the title-and-first-words line. Chosen in
    /// Settings ▸ Appearance; 14 by default.
    var listTextSize: Double = {
        let stored = UserDefaults.standard.double(forKey: "listTextSize")
        return stored == 0 ? 14 : stored
    }() {
        didSet { UserDefaults.standard.set(listTextSize, forKey: "listTextSize") }
    }

    /// Whether the list dims while a note is being written in it — the
    /// other rows receding to 0.3 so the open note stands out. Off by
    /// default; chosen in Settings ▸ Appearance.
    var dimsListWhileEditing: Bool =
        UserDefaults.standard.bool(forKey: "dimsListWhileEditing") {
        didSet {
            UserDefaults.standard.set(dimsListWhileEditing, forKey: "dimsListWhileEditing")
        }
    }

    /// What the Library's articles shelf calls itself — "Articles" or
    /// "Papers", the reader's own word, chosen in Settings ▸ Appearance.
    var articlesShelfLabel: String =
        UserDefaults.standard.string(forKey: "articlesShelfLabel") ?? "Articles" {
        didSet {
            UserDefaults.standard.set(articlesShelfLabel, forKey: "articlesShelfLabel")
        }
    }

    /// Where a clicked note opens — see `NoteLayout`. This machine's
    /// presentation choice, persisted like the theme, chosen in
    /// Settings ▸ Appearance.
    var noteLayout: NoteLayout = {
        if let raw = UserDefaults.standard.string(forKey: "noteLayout"),
           let layout = NoteLayout(rawValue: raw) {
            return layout
        }
        // The older two-way choice, honored once; otherwise the default.
        return UserDefaults.standard.bool(forKey: "noteControlsUnderNote")
            ? .controlsUnder : .inList
    }() {
        didSet {
            UserDefaults.standard.set(noteLayout.rawValue, forKey: "noteLayout")
        }
    }

    // MARK: - View-module state (see LibraryViewModule.swift)

    /// The sidebar place being shown: the document library, or a view module.
    var sidebarSelection: SidebarItem? = .library {
        // Navigating anywhere lifts the People list's one-person
        // narrowing; Show in People re-narrows after it navigates.
        didSet { peopleFilterName = nil }
    }
    /// The person picked in the People list — their mentions fill the
    /// reading column while no document is open.
    var selectedPersonID: String?
    /// Set by Show in People: the list keeps to this one person until
    /// Show All — or any navigation — widens it again.
    var peopleFilterName: String?
    /// Filters the document list and the insight views' rows.
    var searchText = ""
    /// What "Show in <View>" handed over: the selected words for a
    /// view about text snippets, or the note for a view about notes
    /// as nodes. The named view takes it once and it is gone.
    struct ShowInPayload {
        let viewID: String
        let text: String?
        let docID: String
    }
    private(set) var showInPayload: ShowInPayload?

    /// Show in <view>: navigates there carrying the selection or the
    /// note, per the view's declared appetite.
    func showIn(viewID: String, selectedText: String?, docID: String) {
        let module = LibraryViewRegistry.module(id: viewID)
        let text = module?.showInAppetite == .text ? selectedText : nil
        showInPayload = ShowInPayload(viewID: viewID, text: text, docID: docID)
        sidebarSelection = .view(viewID)
    }

    /// A view's one-time pickup of what Show in brought it.
    func takeShowInPayload(for viewID: String) -> ShowInPayload? {
        guard let payload = showInPayload, payload.viewID == viewID else { return nil }
        showInPayload = nil
        return payload
    }

    /// The New Person form, summoned from File ▸ New Person or the
    /// sidebar's People row; the window presents it while this is true.
    var addingPerson = false
    #if os(macOS)
    /// Retains the folder watcher on the App Group inbox where the Safari
    /// extension drops captured AI conversations, so they arrive without
    /// the app in front. Nil until the App Group is configured and the
    /// watch has started.
    @ObservationIgnored var aiInboxWatcher: FolderWatcher?
    #endif
    /// True while the words of a note open in the list are being
    /// typed — the list fades everything around the writing.
    var editingInList = false
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
        restoreReaderLibrary()
        restoreDigestSource()
        placeFinder.onPlace = { [weak self] place in
            self?.currentPlace = place
        }
        placeFinder.begin()
        // Archived is a trash can: the index keeps its documents out of
        // every list and view until they are unfiled.
        index.setArchivedIDs(archivedDocumentIDs)
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
        // The full map, so a note picked from the Archived list still
        // opens in the reader to be retrieved.
        selectedDocID.flatMap { index.allByID[$0]?.doc }
    }

    /// Whether any To Do note is also marked Important — the condition
    /// for the orange To Do row at the head of the sidebar. Read from
    /// the index (not the search-filtered list), so the row's presence
    /// does not come and go with a search.
    var hasImportantToDo: Bool {
        index.timeline.contains { $0.doc.actionValue == .toDo && $0.doc.important }
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
    /// under Archived living in the Filed list alone, and only the
    /// Timeline calendar's chosen span when one is set. Identity cards
    /// are contact records, not correspondence — they live in Settings
    /// ▸ Author, never in the document lists.
    var listedEntries: [IndexEntry] {
        index.timeline.reversed().filter { entry in
            // The open document keeps a seat wherever the reader is —
            // a quote opened from its source's page must show somewhere.
            if entry.id == selectedDocID { return true }
            guard !isMuted(entry.doc.author), !isArchived(entry.doc),
                  entry.doc.documentType != IdentityCard.documentType,
                  // Sources, quotes, and annotations are the reference
                  // shelf's — the Library section shows them. Digests
                  // keep to their own section the same way.
                  !entry.doc.isLibraryKind, !entry.doc.isDigest else { return false }
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
    /// Applies a metadata change to a note's file without disturbing its
    /// words. The file on disk is the truth: the editor autosaves the
    /// note's text there, so the in-memory `doc` a button hands us can be
    /// a beat behind (the index re-reads a document only when it scans).
    /// The one field is merged onto the file's current bytes and written
    /// back — the body is never taken from the possibly-stale copy, so a
    /// standing, Important, or filing set right after typing can no
    /// longer overwrite the words. Returns whether it wrote.
    @discardableResult
    private func mutateNoteFile(_ doc: LiquidDoc,
                               _ change: (inout LiquidDoc) -> Void) -> Bool {
        let fresh = (try? Data(contentsOf: doc.fileURL))
            .flatMap { try? LiquidDoc.decode(data: $0, fileURL: doc.fileURL) }
        var updated = fresh ?? doc
        updated.fileURL = doc.fileURL
        change(&updated)
        do {
            try updated.jsonData().write(to: updated.fileURL, options: .atomic)
            // Show the change at once — the reader's column reflects it
            // before the background rescan of the whole folder lands —
            // then reconcile everything else.
            index.update(updated)
            index.rescan()
            return true
        } catch {
            showNote("Could not update the note: \(error.localizedDescription)")
            return false
        }
    }

    func setDraft(_ isDraft: Bool, for doc: LiquidDoc) {
        if !isDraft, draftDocumentIDs.remove(doc.id) != nil {
            persistDraftIDs()
        }
        guard doc.draft != isDraft else { return }
        mutateNoteFile(doc) { $0.draft = isDraft }
    }

    private func persistDraftIDs() {
        UserDefaults.standard.set(Array(draftDocumentIDs), forKey: "draftDocumentIDs")
    }

    // MARK: - Action (the note's standing, travelling in the file)

    /// Sets the note's action standing — nothing, To Do, In Progress,
    /// Done, or Cancelled — written into the file itself, like the
    /// draft flag, so every device agrees. Choosing a standing is
    /// saving: the draft flag clears with it.
    func setAction(_ action: LiquidDoc.Action?, for doc: LiquidDoc) {
        if action != nil, draftDocumentIDs.remove(doc.id) != nil { persistDraftIDs() }
        mutateNoteFile(doc) {
            $0.action = action?.rawValue
            // Choosing a standing is saving: the draft flag clears with it.
            if action != nil { $0.draft = false }
        }
    }

    // MARK: - Important (a binary standing, travelling in the file)

    /// Marks the note Important or Normal — written into the file
    /// itself, like the draft and action flags, so every device agrees.
    /// Orthogonal to the action axis and to filing: it changes nothing
    /// but the note's importance, and never touches the draft state.
    func setImportant(_ isImportant: Bool, for doc: LiquidDoc) {
        guard doc.important != isImportant else { return }
        mutateNoteFile(doc) { $0.important = isImportant }
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

    /// Folder words that are no longer offered or shown under Files
    /// because they belong to another axis. To Do is an Action now, so
    /// it never appears as a filing folder — the raw and spaced spellings
    /// are both caught.
    static let hiddenFilingFolderNames: Set<String> = ["to do", "todo"]

    static func isHiddenFilingFolder(_ name: String) -> Bool {
        hiddenFilingFolderNames.contains(name.lowercased())
    }

    func folder(for doc: LiquidDoc) -> String? {
        filedFolders[doc.id]
    }

    /// The filing folders that hold something, in their offered order,
    /// then any folder that exists only in the filings.
    var filedFoldersInUse: [String] {
        let used = Set(filedFolders.values)
        var folders = filingFolders.filter(used.contains)
        folders += used.subtracting(folders).sorted()
        return folders
    }

    /// The sidebar's Filed section: the same folders the note column
    /// offers, in the same order — the standard files, the user's own —
    /// then any folder only the filings remember, with Archived last.
    var sidebarFiledFolders: [String] {
        var folders = SidebarCatalog.standardFiles.map(\.folder)
            + ["Letters"]
        func append(_ candidates: [String]) {
            for candidate in candidates
            where candidate.caseInsensitiveCompare(Self.archivedFolderName) != .orderedSame
                && !folders.contains(where: {
                    $0.caseInsensitiveCompare(candidate) == .orderedSame
                }) {
                folders.append(candidate)
            }
        }
        append(filingFolders)
        append(filedFoldersInUse)
        folders.removeAll(where: Self.isHiddenFilingFolder)
        folders.append(Self.archivedFolderName)
        return folders
    }

    func isArchived(_ doc: LiquidDoc) -> Bool {
        filedFolders[doc.id] == Self.archivedFolderName
    }

    /// The ids filed under Archived — what the index hides from the
    /// lists and views.
    private var archivedDocumentIDs: Set<String> {
        Set(filedFolders.filter {
            $0.value.caseInsensitiveCompare(Self.archivedFolderName) == .orderedSame
        }.keys)
    }

    func fileDocument(_ doc: LiquidDoc, under folder: String) {
        filedFolders[doc.id] = folder
        persistFiling()
        syncFolderKind(for: doc, filedUnder: folder)
    }

    func unfile(_ doc: LiquidDoc) {
        guard filedFolders.removeValue(forKey: doc.id) != nil else { return }
        persistFiling()
        syncFolderKind(for: doc, filedUnder: nil)
    }

    /// Filing folders that are also document kinds. Filing a plain note
    /// into one of these raises the filing into the document's own
    /// `documentType`, so the kind travels to every device — the Map's
    /// Journal and Thoughts views read it. Every other folder is a plain
    /// shelf the files never feel.
    static let kindFolders: [String: String] = [
        "Thoughts": LiquidDoc.DocumentType.thought.rawValue,
        "Inspirations": LiquidDoc.DocumentType.inspiration.rawValue,
        "Journal": LiquidDoc.DocumentType.journal.rawValue,
    ]

    /// The kind a filing folder names, if it names one.
    static func kindFolder(for name: String?) -> String? {
        guard let name else { return nil }
        return kindFolders.first {
            $0.key.caseInsensitiveCompare(name) == .orderedSame
        }?.value
    }

    /// Keeps a note's kind in step with its filing. Filing a plain note
    /// under Journal or Thoughts marks it that kind in the document
    /// itself; a thought filed back out returns to a plain note (thought
    /// is purely a filing kind). Journal, which a phone can set at
    /// capture, is never stripped by refiling, and a letter or source
    /// filed under a kind folder keeps its own kind.
    private func syncFolderKind(for doc: LiquidDoc, filedUnder folder: String?) {
        let note = LiquidDoc.DocumentType.note.rawValue
        let thought = LiquidDoc.DocumentType.thought.rawValue
        let current = doc.documentType
        let wanted: String
        if let target = Self.kindFolder(for: folder) {
            guard current == note || current == nil else { return }
            wanted = target
        } else if current == thought {
            wanted = note
        } else {
            return
        }
        guard wanted != current else { return }
        mutateNoteFile(doc) { $0.documentType = wanted }
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
        index.setArchivedIDs(archivedDocumentIDs)
    }

    #if os(macOS)
    /// A folder the user may remove: their own filing folders. The
    /// structural places — the standard files, Letters, and Archived —
    /// return on their own, so offering their removal would be a lie.
    func canRemoveFilingFolder(_ name: String) -> Bool {
        let structural = SidebarCatalog.standardFiles.map(\.folder)
            + ["Letters", Self.archivedFolderName]
        return !structural.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Ctrl-click ▸ Remove Folder…: the category goes; its notes stay.
    /// Filing is a local preference, so nothing touches the files —
    /// the notes simply return to the library at large. Asked about
    /// only when the folder holds something.
    func removeFilingFolder(_ name: String) {
        let filedIDs = filedFolders
            .filter { $0.value.caseInsensitiveCompare(name) == .orderedSame }
            .map(\.key)
        if !filedIDs.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Remove Folder “\(name)”?"
            alert.informativeText = filedIDs.count == 1
                ? "Its note stays in the library — it is just no longer filed here."
                : "Its \(filedIDs.count) notes stay in the library — they are just no longer filed here."
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        for id in filedIDs { filedFolders.removeValue(forKey: id) }
        filingFolders.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        UserDefaults.standard.set(filingFolders, forKey: "filingFolders")
        persistFiling()
        // The place being read is gone: land somewhere real.
        if case .filedFolder(let selected) = sidebarSelection,
           selected.caseInsensitiveCompare(name) == .orderedSame {
            sidebarSelection = .library
        }
    }

    /// Ctrl-click ▸ Delete File…: after confirmation, the document's
    /// file moves to the Trash — recoverable there, but gone from the
    /// shared folder for everyone who syncs it. The one deliberately
    /// destructive act in the app, so it is asked about every time,
    /// and the Trash keeps the words.
    func deleteFile(_ doc: LiquidDoc) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(doc.title)”?"
        alert.informativeText = "“\(doc.fileURL.lastPathComponent)” moves to the Trash and leaves the shared folder — for everyone who syncs it. (Filing under Archived hides a note without removing it.)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: doc.fileURL, resultingItemURL: nil)
        } catch {
            showNote("Could not delete the file: \(error.localizedDescription)")
            return
        }
        if filedFolders.removeValue(forKey: doc.id) != nil { persistFiling() }
        if selectedDocID == doc.id { selectedDocID = nil }
        index.rescan()
        showNote("“\(doc.title)” moved to the Trash.")
    }

    /// How many notes are filed under Archived and still on disk —
    /// what "Delete All Archived…" would move to the Trash.
    var archivedCount: Int {
        archivedDocumentIDs.filter { index.allByID[$0] != nil }.count
    }

    /// Empties the Archive in one go: every note filed under Archived
    /// moves to the Trash. As destructive as a single delete but many
    /// at once, so it is asked about with its count; the Trash keeps
    /// the words. Only the files that trash cleanly leave their filing.
    func deleteAllArchived() {
        let ids = archivedDocumentIDs
        let resolvable = ids.filter { index.allByID[$0] != nil }
        guard !resolvable.isEmpty else {
            showNote("Nothing is archived.")
            return
        }
        let alert = NSAlert()
        let noun = resolvable.count == 1 ? "item" : "items"
        alert.messageText = "Delete all \(resolvable.count) archived \(noun)?"
        alert.informativeText = "They move to the Trash and leave the shared folder — for everyone who syncs it. This cannot be undone from within the app."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var trashedIDs: [String] = []
        var firstError: String?
        for id in ids {
            guard let url = index.allByID[id]?.doc.fileURL else { continue }
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                trashedIDs.append(id)
            } catch {
                if firstError == nil { firstError = error.localizedDescription }
            }
        }
        for id in trashedIDs { filedFolders.removeValue(forKey: id) }
        if !trashedIDs.isEmpty { persistFiling() }
        if let selected = selectedDocID, trashedIDs.contains(selected) {
            selectedDocID = nil
        }
        index.rescan()
        if let firstError {
            showNote("Moved \(trashedIDs.count) to the Trash; some could not be deleted: \(firstError)")
        } else {
            let done = trashedIDs.count == 1 ? "item" : "items"
            showNote("Moved \(trashedIDs.count) archived \(done) to the Trash.")
        }
    }

    // MARK: - Renaming files

    /// The human half of the document's file name — what precedes the
    /// "--<id>" suffix, or "" when the file is named by its bare id.
    /// A file outside the convention (a legacy name) is offered whole.
    private static func fileNameSlug(of doc: LiquidDoc) -> String {
        var stem = doc.fileURL.lastPathComponent
        if stem.lowercased().hasSuffix("." + LiquidDoc.fileExtension) {
            stem = String(stem.dropLast(LiquidDoc.fileExtension.count + 1))
        }
        if stem.lowercased() == doc.id { return "" }
        if stem.lowercased().hasSuffix("--" + doc.id) {
            return String(stem.dropLast(doc.id.count + 2))
        }
        return stem
    }

    /// Ctrl-click ▸ Rename File…: changes the human half of a document's
    /// file name and nothing else. The address stays in the name —
    /// "<slug>--<id>.liquid.json", or the bare id when the slug is
    /// cleared — so citations keep resolving and the folder stays
    /// browsable, the reason the format forbids free renames. The
    /// document's contents are untouched.
    func renameFile(of doc: LiquidDoc) {
        let alert = NSAlert()
        alert.messageText = "Rename File"
        alert.informativeText = "The file's human-readable name. Its address — \(doc.id) — stays in the file name, so links to “\(doc.title)” keep resolving."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = Self.fileNameSlug(of: doc)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let slug = field.stringValue.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let ext = LiquidDoc.fileExtension
        let name = slug.isEmpty ? "\(doc.id).\(ext)" : "\(slug)--\(doc.id).\(ext)"
        let destination = doc.fileURL.deletingLastPathComponent()
            .appendingPathComponent(name)
        guard destination.path != doc.fileURL.path else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            showNote("A file named “\(name)” is already in the folder.")
            return
        }
        do {
            try FileManager.default.moveItem(at: doc.fileURL, to: destination)
            index.rescan()
            showNote("Renamed to “\(name)”.")
        } catch {
            showNote("Could not rename the file: \(error.localizedDescription)")
        }
    }
    #endif

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
                if index.allByID[doc.id] != nil { skipped += 1; continue }
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
        makeNewDocument(type: .note, landing: .library)
    }

    /// A new note born with a standing — To Do, Done, a Question —
    /// landing in that standing's place. Having a standing, it is no
    /// draft. Ctrl-click an Action row invokes this.
    func newNote(action: LiquidDoc.Action) {
        makeNewDocument(type: .note, landing: .action(action), action: action)
    }

    /// A new note filed under a folder from the start — landing in that
    /// folder's list. Filing settles it, so it is no draft. Ctrl-click
    /// a Filed row invokes this.
    func newNote(filedUnder folder: String) {
        makeNewDocument(type: .note, landing: .filedFolder(folder), fileUnder: folder)
    }

    /// A new letter: a note in every way, marked `letter` — Knowledge
    /// Space's internal category until Digital Letters' sending arrives.
    /// It drafts under Draft Letters, and its File button files it
    /// under Letters.
    func newLetter() {
        makeNewDocument(type: .letter, landing: .draftLetters)
    }

    private func makeNewDocument(type: LiquidDoc.DocumentType, landing: SidebarItem,
                                 action: LiquidDoc.Action? = nil,
                                 fileUnder: String? = nil) {
        guard let folderURL = index.folderURL else {
            showNote("Choose a library folder first — notes live there.")
            return
        }
        let created = Date.now
        let id = LiquidAddress.makeID(author: authorName, created: created) { candidate in
            self.index.isIDTaken(candidate)
        }
        // A plain new document starts as a draft — it lists in the Inbox
        // awaiting its Action or File. But one born into a standing or a
        // folder already has its verdict, so it is no draft. The flag
        // travels in the file, so other devices agree.
        let settled = action != nil || fileUnder != nil
        var doc = LiquidDoc(format: LiquidDoc.knownFormat,
                            id: id,
                            title: "Untitled",
                            author: authorName,
                            created: created,
                            body: [],
                            links: [],
                            wraps: nil,
                            draft: !settled,
                            documentType: type.rawValue,
                            location: currentPlace,
                            fileURL: folderURL.appendingPathComponent(id)
                                .appendingPathExtension(LiquidDoc.fileExtension))
        if let action { doc.action = action.rawValue }
        // A laptop moves between notes — refresh the place for the next.
        placeFinder.begin()
        do {
            try doc.jsonData().write(to: doc.fileURL, options: .atomic)
        } catch {
            showNote("Could not create the note: \(error.localizedDescription)")
            return
        }
        // Filing is the reader's own, kept locally — set after the file
        // exists so the folder map has a document to point at.
        if let fileUnder { fileDocument(doc, under: fileUnder) }
        // Show the note at once: seat it in the index so the editor can
        // resolve it immediately, land on it, then let the rescan (which
        // scans the whole folder in the background) reconcile.
        index.insert(doc)
        sidebarSelection = landing
        selectedDocID = id
        index.rescan()
    }

    // MARK: - Library upkeep

    /// One pass once the library has been read. The action standing now
    /// lives in each note's file; upkeep migrates the old way of saying
    /// it — a note filed under To Do, In Progress, or Done gets that
    /// standing written into it and leaves the folder, and those names
    /// leave the filing offer.
    private var upkeepDone = false

    func libraryUpkeep() {
        guard !upkeepDone, index.folderURL != nil, !index.isScanning else { return }
        upkeepDone = true
        var migrated = 0
        for (docID, folder) in filedFolders {
            let action: LiquidDoc.Action? = switch folder.lowercased() {
            case "to do": .toDo
            case "in progress": .inProgress
            case "done": .done
            default: nil
            }
            guard let action, let doc = index.allByID[docID]?.doc else { continue }
            var updated = doc
            updated.action = action.rawValue
            guard (try? updated.jsonData().write(to: updated.fileURL, options: .atomic)) != nil
            else { continue }
            filedFolders.removeValue(forKey: docID)
            migrated += 1
        }
        let legacyFolders = ["to do", "in progress", "done"]
        let hadLegacy = filingFolders.contains { legacyFolders.contains($0.lowercased()) }
        if hadLegacy {
            filingFolders.removeAll { legacyFolders.contains($0.lowercased()) }
            UserDefaults.standard.set(filingFolders, forKey: "filingFolders")
        }
        if migrated > 0 || hadLegacy {
            persistFiling()
            index.rescan()
        }
        if migrated > 0 {
            showNote("To Do, In Progress, and Done now travel inside the notes — \(migrated) moved over.")
        }
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

    /// People the reader raised to the top of the People list — held by
    /// listing id, this laptop's own choice.
    var highlightedPeople: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "highlightedPeople") ?? []) {
        didSet {
            UserDefaults.standard.set(Array(highlightedPeople), forKey: "highlightedPeople")
        }
    }

    /// People held out of the People list without deleting them — the
    /// record and card stay; the row is simply not shown.
    var hiddenPeople: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "hiddenPeople") ?? []) {
        didSet {
            UserDefaults.standard.set(Array(hiddenPeople), forKey: "hiddenPeople")
        }
    }

    func toggleHighlightedPerson(_ id: String) {
        if highlightedPeople.contains(id) {
            highlightedPeople.remove(id)
        } else {
            highlightedPeople.insert(id)
        }
    }

    func setPersonHidden(_ hidden: Bool, _ id: String) {
        if hidden {
            hiddenPeople.insert(id)
            if selectedPersonID == id { selectedPersonID = nil }
        } else {
            hiddenPeople.remove(id)
        }
    }

    /// The folder where Reader keeps its PDFs, once granted — remembered
    /// as a security-scoped bookmark like the community folder, scanned
    /// for Visual-Meta PDFs at launch and on request (ReaderLibrary.swift).
    var readerLibraryURL: URL?
    /// The folder the Digest distills — the user's documents, granted
    /// in Settings ▸ Library — and its scan's standing.
    var digestSourceURL: URL?
    var digestScanRunning = false
    var digestProgress: AnalysisProgress?
    /// One quiet Reader Library scan per run, once the index is read.
    var readerScanDone = false
    /// A scan already walking the Reader Library; a second waits its turn.
    var readerScanRunning = false
    /// Analyze New already studying the shelf; the button rests meanwhile.
    var sourceAnalysisRunning = false
    /// Analyze New's progress, worn by the button itself.
    struct AnalysisProgress {
        var done: Int
        var total: Int
    }
    var sourceAnalysisProgress: AnalysisProgress?
    /// Re-scan's progress, worn by its button.
    var readerRescanProgress: AnalysisProgress?
    /// The Authors shelf's open author. App state, not view state:
    /// "Show in Authors" sets it directly and the shelf arrives
    /// selected, however the view's lifecycle falls that instant —
    /// the hand-off dance (pending value, consumed on appearance)
    /// lost to identity-preserving shelf switches.
    var selectedShelfAuthor: String?

    /// A term chosen on a source's page, opened in a view: the term
    /// becomes the window's search — filter-driven views open already
    /// narrowed to it — and travels as the Show-in payload for views
    /// that take one directly.
    func showTerm(_ term: String, inView viewID: String, from docID: String) {
        searchText = term
        showInPayload = ShowInPayload(viewID: viewID, text: term, docID: docID)
        sidebarSelection = .view(viewID)
    }

    /// A cited name, opened in the Library's Authors shelf — selected.
    func showCitedAuthor(_ name: String) {
        selectedShelfAuthor = name
        sidebarSelection = .sourceShelf(.authors)
    }

    /// A name opened in the People place: the list narrows to that one
    /// person, selected, and the reading column shows their page.
    /// Matching goes through the person record's own test, so aliases
    /// answer too. The sidebar moves first — navigation clears the
    /// narrowing, so the narrowing must come after.
    func showPerson(_ name: String) {
        sidebarSelection = .people
        peopleFilterName = name
        if let listing = peopleListings.first(where: { $0.person.answersTo(name) }) {
            selectedPersonID = listing.id
            selectedDocID = nil
        }
    }

    /// True when the restored folder can be read but not written — a
    /// bookmark minted while the app's permission was read-only. Only a
    /// fresh pick can renew it; ContentView opens the picker on this.
    private(set) var folderNeedsRepick = false

    func chooseFolder(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        saveBookmark(url)
        index.setFolder(url)
        shareContacts(into: url)
        folderNeedsRepick = false
    }

    // MARK: - People (the contact directory shared with Digital Letters)

    /// Puts the contact directory into the community folder, where the
    /// phone, the headset, and Digital Letters find it. The user's own
    /// record is added first if the directory does not hold one yet.
    private func shareContacts(into folder: URL) {
        if people.person(named: authorName) == nil,
           !authorName.trimmingCharacters(in: .whitespaces).isEmpty {
            var me = Person(displayName: authorName)
            let identity = authorIdentity
            me.orcid = identity.orcid
            me.affiliation = identity.affiliation
            people.upsert(me)
        }
        people.attach(folder: folder)
        // The nickname registry the phone publishes — read-only here.
        localities.attach(folder: folder)
        if people.communityWriteFailed {
            showNote("Contact information could not be written to the shared folder — choose the folder again to renew write access.")
        }
        #if os(macOS)
        publishPortraits()
        #endif
    }

    /// The distinct names credited as authors in the library — offered
    /// by the person form's "This is also:" for names without records.
    var libraryAuthorNames: [String] {
        var seen = Set<String>()
        var names: [String] = []
        for entry in index.timeline {
            let name = entry.doc.author.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            names.append(name)
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    #if os(macOS)
    /// Writes every person's image into the community folder
    /// (Portraits/<localID>.png) and records the file on their JSON
    /// record in People.json — so every machine shows the face with the
    /// name. Idempotent: images already current are left alone.
    func publishPortraits() {
        guard let folder = index.folderURL else { return }
        for person in people.people {
            guard let relative = portraits.publish(personID: person.localID, into: folder),
                  person.portraitFile != relative else { continue }
            var updated = person
            updated.portraitFile = relative
            people.upsert(updated)
        }
    }

    #endif

    /// Opens an `origamitext://open/<id>#<fragment>` link. Per the format,
    /// every link except `revises` follows through to the latest revision.
    func open(url: URL) {
        guard url.scheme?.lowercased() == "origamitext" else { return }
        let id = LiquidAddress.canonical(url.host() ?? url.lastPathComponent)
        open(id: id, fragment: url.fragment)
    }

    func open(id: String, fragment: String? = nil) {
        let target = index.latestRevision(of: id)
        guard index.allByID[target] != nil else { return }
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
        shareContacts(into: url)
        folderNeedsRepick = !FileManager.default.isWritableFile(atPath: url.path)
    }
}
