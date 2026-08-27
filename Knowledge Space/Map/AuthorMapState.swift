//
//  AuthorMapState.swift
//  Knowledge Space
//
//  State for the Author Map volume: the MapEngine, the open document, the
//  view transform between map coordinates and the volume, and the AI agent
//  session with its chat log.
//

#if os(visionOS)
import SwiftUI
import Observation
import WidgetKit

/// One document in the open community folder, listed by its own title.
struct FolderDocument: Identifiable {
    let url: URL
    let title: String
    var id: String { url.path }
}

/// The left-arm menu's three cuts across the community folder. Choosing
/// one shows only its documents as the map, the way the whole folder is
/// shown by default.
enum MapLibraryCategory: String, CaseIterable, Identifiable {
    case thoughts, journal, articles
    var id: String { rawValue }

    var title: String {
        switch self {
        case .thoughts: "Thoughts"
        case .journal: "Journal"
        case .articles: "Articles"
        }
    }

    var systemImage: String {
        switch self {
        case .thoughts: "lightbulb"
        case .journal: "book.closed"
        case .articles: "doc.richtext"
        }
    }

    /// Whether a document belongs in this category.
    func matches(_ doc: LiquidDoc) -> Bool {
        switch self {
        case .thoughts:
            // A note filed under Thoughts on the Mac, which raises the
            // filing into the document as the `thought` kind so it travels
            // here. A plain, unfiled note is not a Thought.
            return doc.documentType == LiquidDoc.DocumentType.thought.rawValue
        case .journal:
            return doc.documentType == LiquidDoc.DocumentType.journal.rawValue
        case .articles:
            // A PDF scanned into the library: any document wrapping an
            // external file, whatever kind the sidecar declares.
            return doc.wraps != nil
        }
    }
}

/// One entry in the agent conversation shown in the panel.
struct AgentChatEntry: Identifiable {
    enum Role {
        case user
        case assistant
        case activity
    }

    let id = UUID()
    var role: Role
    var text: String
}

@MainActor @Observable
final class AuthorMapState {

    let engine = MapEngine()

    /// Bumped whenever the engine changes, so views re-read positions.
    private(set) var revision = 0

    private(set) var documentURL: URL?
    private(set) var hasUnsavedChanges = false
    var lastError: String?

    /// The format the open document arrived in; saves go back the same
    /// way, never converting as a side effect.
    private(set) var documentFormat: MapDocumentFormat?

    /// The open document's own title, read from its JSON on open.
    private(set) var documentTitle = "Map"

    // MARK: - View transform (map points <-> space points)

    /// The original Author mapping: 1000 canvas points to the meter, the
    /// map hanging at eye height in front of the viewer, z in meters.
    /// Nothing is scaled to fit and nothing clips — nodes go anywhere.
    /// `pointsPerMeter` is supplied by the view from its physical metrics.
    var pointsPerMeter: Double = 1360
    private static let metersPerCanvasPoint = 0.001

    /// The canvas point placed at the space anchor, set once per load so
    /// the map starts in front of the viewer.
    private(set) var mapCenter = SIMD2<Double>(0, 0)

    /// Points per canvas point.
    private var canvasScale: Double { Self.metersPerCanvasPoint * pointsPerMeter }

    func viewPosition(of node: FlowNode) -> SIMD3<Double> {
        let position = engine.position(of: node.identifier)
        return SIMD3(
            (Double(position.x) - mapCenter.x) * canvasScale,
            (Double(position.y) - mapCenter.y) * canvasScale,
            Double(position.z) * pointsPerMeter
        )
    }

    func mapDelta(fromViewDelta delta: SIMD3<Double>) -> SIMD3<Double> {
        guard canvasScale > 0 else { return .zero }
        return SIMD3(delta.x / canvasScale,
                     delta.y / canvasScale,
                     delta.z / pointsPerMeter)
    }

    /// Centers the map on its visible nodes; the scale never changes.
    func recenter() {
        let positions = engine.visibleNodes.map { engine.position(of: $0.identifier) }
        guard !positions.isEmpty else {
            mapCenter = .zero
            return
        }
        let xs = positions.map { Double($0.x) }
        let ys = positions.map { Double($0.y) }
        mapCenter = SIMD2((xs.min()! + xs.max()!) / 2, (ys.min()! + ys.max()!) / 2)
    }

    // MARK: - Expansion (the reader's transient view state, never saved)

    /// Cards whose definition is unfolded — the original Map's
    /// double-tap expansion, kept apart from selection.
    private(set) var expandedNodes: Set<FlowNodeIdentifier> = []

    func toggleExpanded(_ id: FlowNodeIdentifier) {
        if expandedNodes.contains(id) {
            expandedNodes.remove(id)
        } else {
            expandedNodes.insert(id)
        }
    }

    func setExpanded<IDs: Collection>(_ ids: IDs, _ expanded: Bool) where IDs.Element == FlowNodeIdentifier {
        if expanded {
            expandedNodes.formUnion(ids)
        } else {
            expandedNodes.subtract(ids)
        }
    }

    /// The original's Close All: every card folds back to its term.
    func collapseAll() {
        expandedNodes = []
    }

    // MARK: - Focus (the original's show-only-the-selection mode)

    private(set) var isFocused = false

    func toggleFocus() {
        if isFocused {
            isFocused = false
        } else if !engine.selection.isEmpty {
            isFocused = true
        }
    }

    /// The nodes the space shows: the engine's visible set, narrowed to
    /// the selection and its direct neighbours while focused — the
    /// original's focus().
    var spaceNodes: [FlowNode] {
        let nodes = engine.visibleNodes
        guard isFocused, !engine.selection.isEmpty else { return nodes }
        var kept = engine.selection
        for connection in engine.document.connections {
            if engine.selection.contains(connection.startNodeIdentifier) {
                kept.insert(connection.endingNodeIdentifier)
            } else if engine.selection.contains(connection.endingNodeIdentifier) {
                kept.insert(connection.startNodeIdentifier)
            }
        }
        return nodes.filter { kept.contains($0.identifier) }
    }

    /// Whether the immersive map space is currently open; kept by the
    /// space view so window scenes don't try to open it twice.
    var isMapSpaceOpen = false

    /// The Sphere Weave's centered element, shared between its
    /// immersive space and its control bar; and whether the weave
    /// space is open — only one immersive space can be.
    var weaveCenter: WeaveCenter = .keyword("hypertext")
    var isWeaveSpaceOpen = false

    /// Whether the flexible room space is currently open — only one immersive
    /// space can hold the room at a time.
    var isFlexSpaceOpen = false

    /// The toolbar and settings windows report themselves open here, so
    /// the wrist bangles can toggle them from inside the space.
    var isControlsWindowOpen = false
    var isSettingsWindowOpen = false

    /// Set when the toolbar is dismissed deliberately (the left bangle).
    /// Any other close reopens it — the map is never left controlless.
    var controlsToggledOff = false

    // MARK: - Document lifecycle

    private static let bookmarkKey = "knowledgeMapDocumentBookmark"
    private static let folderBookmarkKey = "knowledgeMapFolderBookmark"
    private static let readerFolderBookmarkKey = "knowledgeMapReaderFolderBookmark"

    /// The community folder the picker granted, and the documents in it.
    private(set) var folderURL: URL?
    private(set) var folderDocuments: [FolderDocument] = []

    /// Where a node opened to. A folder-map node stands for another
    /// Knowledge Space document, opening in place (`.document`); the
    /// folder itself is the root map (`.folder`).
    enum OpenTarget: Equatable {
        case folder
        case document(URL)
    }

    /// The trail of maps opened by drilling into linked documents, so a
    /// reader can step back out to where they came from. Only
    /// `openLinkedDocument`/`goBack` touch it; opening a fresh root
    /// (a folder, the Library) clears it.
    private(set) var navStack: [OpenTarget] = []
    var canGoBack: Bool { !navStack.isEmpty }

    /// A pending request to open an external file in another app, watched
    /// by the controls window (immersive spaces cannot host the handoff
    /// sheet). Carries a fresh id each time so re-opening the same file
    /// fires again.
    var externalOpenRequest: ExternalOpenRequest?

    /// The Reader library folder, chosen once and remembered by bookmark,
    /// so external files a node names — PDFs above all — resolve even
    /// when they live outside the community folder.
    private(set) var readerLibraryURL: URL?
    private var accessedReaderFolder: URL?

    /// Address → document / file, rebuilt from each folder scan so a node
    /// (whose identifier is its document's address) resolves to the file
    /// on disk without re-reading anything.
    private var docByID: [String: LiquidDoc] = [:]
    private var urlByID: [String: URL] = [:]

    /// Whether the engine currently shows the folder itself as the map —
    /// every document a node, links between documents the threads.
    private(set) var showingFolderMap = false

    /// The category the left-arm menu narrowed the folder map to, if any.
    /// Nil is the whole folder. Kept across background rescans so a reader
    /// browsing one category is not thrown back to everything.
    private(set) var mapCategory: MapLibraryCategory?

    /// Bumped each time a different map loads, so the view can refit.
    private(set) var loadCount = 0

    /// The folder's decoded documents from the last scan, kept so the
    /// folder map can rebuild without re-reading every file.
    private var scannedDocs: [LiquidDoc] = []

    /// The same scan, readable by the other visionOS scenes — the
    /// Sphere Weave builds its shells from these documents.
    var weaveDocuments: [LiquidDoc] { scannedDocs }

    /// Documents that exist in the folder only as iCloud placeholders,
    /// counted at the last scan. On a headset that has never held the
    /// community folder, the first scan finds nothing *but* these.
    private(set) var pendingDownloadCount = 0

    /// The scan re-running itself while placeholders remain: there is
    /// no folder watcher here (the Mac's lives in AppState), so iCloud
    /// arrivals would otherwise sit unseen until a manual Check Again.
    private var downloadRescanTask: Task<Void, Never>?
    private var downloadRescanAttempts = 0

    /// The folder holding a live security scope. The scope stays open for
    /// the whole session so the documents inside remain readable and
    /// saveable; it is released only when another folder replaces it.
    private var accessedFolder: URL?

    init() {
        engine.onChange = { [weak self] _ in
            self?.revision += 1
            self?.hasUnsavedChanges = true
        }
    }

    /// Routes a picked URL: folders become the community folder, files
    /// open as documents. A `.liquid` package is a directory on disk
    /// but a document at heart, so it goes the document way.
    func open(url: URL) {
        if url.hasDirectoryPath && url.pathExtension.lowercased() != "liquid" {
            openFolder(url: url)
        } else {
            openDocument(url: url)
        }
    }

    func openFolder(url: URL) {
        if let previous = accessedFolder {
            previous.stopAccessingSecurityScopedResource()
            accessedFolder = nil
        }
        if url.startAccessingSecurityScopedResource() {
            accessedFolder = url
        }
        folderURL = url
        lastError = nil
        downloadRescanAttempts = 0
        if let bookmark = try? url.bookmarkData() {
            UserDefaults.standard.set(bookmark, forKey: Self.folderBookmarkKey)
        }
        rescanFolder()
    }

    /// Whether a folder scan is in flight; the Library window shows a
    /// progress note instead of "no documents" while one is.
    private(set) var folderScanRunning = false

    /// Lists the folder's documents the way the library scan does:
    /// recursively, skipping hidden files, asking iCloud to download
    /// placeholders it finds along the way. All the file work — the
    /// iCloud enumeration, the download requests, every read — runs
    /// off the main actor: over iCloud it can stall for seconds, and
    /// it must never freeze the window at the moment the folder is
    /// picked. When no single document is open, the folder itself
    /// becomes the map.
    func rescanFolder() {
        guard let folder = folderURL, !folderScanRunning else { return }
        folderScanRunning = true
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                Self.readFolder(folder)
            }.value
            folderScanRunning = false
            // A folder picked mid-scan supersedes these results.
            guard folder == folderURL else { return }
            apply(found)
        }
    }

    /// One scan's findings, carried back to the main actor whole.
    private struct FolderScan {
        var docs: [LiquidDoc] = []
        var documents: [FolderDocument] = []
        var pendingDownloads = 0
    }

    nonisolated private static func readFolder(_ folder: URL) -> FolderScan {
        LibraryScanner.requestICloudDownloads(in: folder)
        var found = FolderScan()
        if let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let url as URL in enumerator where LiquidDoc.isDocumentFile(url) {
                guard let data = try? Data(contentsOf: url),
                      let doc = try? LiquidDoc.decode(data: data, fileURL: url) else {
                    found.documents.append(FolderDocument(url: url, title: url.lastPathComponent))
                    continue
                }
                found.docs.append(doc)
                found.documents.append(FolderDocument(url: url, title: doc.title))
            }
        }
        found.pendingDownloads = LibraryScanner.pendingDocumentDownloads(in: folder)
        return found
    }

    private func apply(_ found: FolderScan) {
        scannedDocs = found.docs
        rebuildIndex()
        publishWidgetSnapshots()
        folderDocuments = found.documents.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }

        // Files still on their way from iCloud: keep looking until they
        // land, so the map opens by itself instead of asking the reader
        // to guess when to Check Again.
        pendingDownloadCount = found.pendingDownloads
        if pendingDownloadCount > 0 {
            scheduleDownloadRescan()
        } else {
            downloadRescanTask?.cancel()
            downloadRescanTask = nil
            downloadRescanAttempts = 0
        }

        // Show (or refresh) the folder map — but during the download
        // rescans, only when new documents actually arrived, so the
        // map is not reloaded and recentered every tick.
        if documentURL == nil || showingFolderMap {
            if !showingFolderMap || scannedDocs.count != shownFolderDocCount {
                // Keep the reader's chosen category across the refresh.
                loadFolderMap()
            }
        }
    }

    // MARK: - Widget snapshots

    /// Notes checked To Do, newest first — what the To Do widget and the
    /// listing window show.
    var toDoDocuments: [LiquidDoc] {
        scannedDocs.filter { $0.actionValue == .toDo }
            .sorted { $0.listedDate > $1.listedDate }
    }

    /// Journal notes, newest first.
    var journalDocuments: [LiquidDoc] {
        scannedDocs.filter { $0.documentType == LiquidDoc.DocumentType.journal.rawValue }
            .sorted { $0.listedDate > $1.listedDate }
    }

    /// After each scan, hands the widgets a fresh snapshot of the To Do
    /// and Journal lists through the shared App Group, then asks WidgetKit
    /// to redraw. The top fifteen of each — a glance, not the archive.
    private func publishWidgetSnapshots() {
        func items(_ docs: [LiquidDoc]) -> [KSWidget.Item] {
            docs.prefix(15).map {
                KSWidget.Item(id: $0.id,
                              title: $0.title,
                              subtitle: $0.location ?? "",
                              dateText: $0.listedDateText)
            }
        }
        KSWidget.write(items(toDoDocuments), for: .toDo)
        KSWidget.write(items(journalDocuments), for: .journal)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// The document count the folder map last loaded with; a download
    /// rescan that found nothing new skips the reload.
    private var shownFolderDocCount = 0

    /// Re-runs the scan in a moment, while iCloud placeholders remain.
    /// Capped so a stalled download cannot tick forever — five minutes
    /// of trying; Check Again (or re-picking the folder) starts over.
    private func scheduleDownloadRescan() {
        guard downloadRescanTask == nil, downloadRescanAttempts < 150 else { return }
        downloadRescanAttempts += 1
        downloadRescanTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.downloadRescanTask = nil
            self.rescanFolder()
        }
    }

    /// How many documents the folder map will carry. Every card in the
    /// immersive space is two live SwiftUI surfaces in the compositor
    /// (backboardd); an uncapped folder of many hundreds inflated it
    /// until the system killed it and the whole interface restarted.
    private static let mapDocumentCap = 150

    /// What the folder map is made of: the writing — notes, letters,
    /// documents — not the library shelves (sources, quotes,
    /// annotations the Reader import mints by the hundred), newest
    /// first when the folder holds more than the map can carry.
    private var mapDocuments: [LiquidDoc] {
        // A chosen category speaks for itself: show exactly its documents,
        // shelves included (Articles are sidecars, a shelf kind), newest
        // first past the cap.
        if let mapCategory {
            let matching = scannedDocs.filter(mapCategory.matches)
            guard matching.count > Self.mapDocumentCap else { return matching }
            return Array(matching.sorted { $0.listedDate > $1.listedDate }
                .prefix(Self.mapDocumentCap))
        }
        var writing = scannedDocs.filter { !$0.isLibraryKind && !$0.isDigest }
        // A folder of nothing but shelves still deserves a map.
        if writing.isEmpty { writing = scannedDocs }
        guard writing.count > Self.mapDocumentCap else { return writing }
        return Array(writing.sorted { $0.listedDate > $1.listedDate }
            .prefix(Self.mapDocumentCap))
    }

    /// Shows the whole community folder as the map. The left-arm menu's
    /// categories narrow it with `showCategory`.
    func showFolderMap(keepingHistory: Bool = false) {
        mapCategory = nil
        loadFolderMap(keepingHistory: keepingHistory)
    }

    /// Shows one library category alone — the left-arm menu's Thoughts,
    /// Journal, or Articles — as its own folder map.
    func showCategory(_ category: MapLibraryCategory, keepingHistory: Bool = false) {
        mapCategory = category
        loadFolderMap(keepingHistory: keepingHistory)
    }

    /// Loads the folder map into the engine: documents as nodes, links as
    /// threads, positions from the reader's saved arrangement. Honors the
    /// current `mapCategory`, so a background rescan keeps the reader in
    /// the category they chose.
    private func loadFolderMap(keepingHistory: Bool = false) {
        guard let folder = folderURL, !scannedDocs.isEmpty else { return }
        if !keepingHistory { navStack.removeAll() }
        if documentURL != nil, hasUnsavedChanges {
            save()
        }

        let contents = KnowledgeMapDocument.folderContents(documents: mapDocuments)
        // The Journal view is a timeline: its entries carry dates, so they
        // line up left to right by day rather than taking the reader's
        // saved arrangement. Every other view keeps its saved positions.
        if mapCategory == .journal {
            applyTimelineLayout(to: contents.flowDocument, documents: mapDocuments)
        } else {
            applySavedFolderLayout(to: contents.flowDocument, folder: folder)
        }
        engine.load(document: contents.flowDocument, glossary: contents.glossary)
        shownFolderDocCount = scannedDocs.count
        documentURL = nil
        documentFormat = nil
        documentTitle = mapCategory?.title ?? folder.lastPathComponent
        showingFolderMap = true
        hasUnsavedChanges = false
        lastError = nil
        expandedNodes = []
        isFocused = false
        recenter()
        loadCount += 1
        agentSession?.clearHistory()
    }

    // MARK: - Folder arrangement (the reader's own, kept locally)

    private func folderLayoutKey(_ folder: URL) -> String {
        "knowledgeMapFolderLayout:" + folder.path
    }

    private func applySavedFolderLayout(to document: FlowDocument, folder: URL) {
        guard let saved = UserDefaults.standard.dictionary(forKey: folderLayoutKey(folder))
            as? [String: [Double]] else { return }
        let ids = Set(document.nodes.map(\.identifier))
        for (id, xyz) in saved where ids.contains(id) && xyz.count == 3 {
            document.layout.set(position: NodePosition(x: xyz[0], y: xyz[1], z: xyz[2]), for: id)
        }
    }

    /// Lays documents in a single row, left to right by date — the
    /// earliest at the left. Computed fresh each load (never the reader's
    /// saved arrangement), so the Journal timeline always reads in order.
    /// 260 canvas points is the folder grid's own column gap; a little
    /// more keeps the dated titles from touching.
    private func applyTimelineLayout(to document: FlowDocument, documents: [LiquidDoc]) {
        let ordered = documents.sorted { $0.listedDate < $1.listedDate }
        let spacing = 300.0
        let startX = -Double(ordered.count - 1) / 2 * spacing
        for (index, doc) in ordered.enumerated() {
            document.layout.set(position: NodePosition(x: startX + Double(index) * spacing, y: 0, z: 0),
                                for: doc.id)
        }
    }

    private func saveFolderLayout() {
        guard let folder = folderURL else { return }
        var positions: [String: [Double]] = [:]
        for node in engine.document.nodes {
            let p = engine.position(of: node.identifier)
            positions[node.identifier] = [Double(p.x), Double(p.y), Double(p.z)]
        }
        UserDefaults.standard.set(positions, forKey: folderLayoutKey(folder))
        hasUnsavedChanges = false
    }

    func openDocument(url: URL, keepingHistory: Bool = false) {
        do {
            // A fresh open (from the Library or the picker) starts a new
            // trail; only drilling into a link keeps the way back.
            if !keepingHistory { navStack.removeAll() }
            // Switching away from an edited map keeps its changes.
            if hasUnsavedChanges {
                save()
            }

            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }

            let (contents, format) = try MapDocumentIO.load(from: url)
            engine.load(document: contents.flowDocument, glossary: contents.glossary)
            documentURL = url
            documentFormat = format
            documentTitle = contents.title ?? url.lastPathComponent
            showingFolderMap = false
            mapCategory = nil
            hasUnsavedChanges = false
            lastError = nil
            expandedNodes = []
            isFocused = false
            recenter()
            loadCount += 1
            agentSession?.clearHistory()

            if let bookmark = try? url.bookmarkData() {
                UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
            }
        } catch {
            lastError = "\(error)"
        }
    }

    // MARK: - Linked documents (the nested knowledge environment)

    /// Rebuilds the address lookups from the last folder scan. A node's
    /// identifier is its document's address, so this is the table that
    /// turns a node back into the file it stands for.
    private func rebuildIndex() {
        var docs: [String: LiquidDoc] = [:]
        var urls: [String: URL] = [:]
        for doc in scannedDocs {
            docs[doc.id] = doc
            urls[doc.id] = doc.fileURL
        }
        docByID = docs
        urlByID = urls
    }

    /// The document a node stands for, resolved by address: the node's own
    /// identifier first (folder-map document nodes), then a `documentPath`
    /// an Author document-link node carries.
    private func document(for node: FlowNode) -> LiquidDoc? {
        if let doc = docByID[node.identifier] { return doc }
        if let path = node.documentPath ?? node.glossaryEntry?.documentPath {
            return docByID[LiquidAddress.canonical(path)]
        }
        return nil
    }

    /// The file a node's linked **native** document lives in, when that
    /// document is one Knowledge Space opens in place. A sidecar wrapping
    /// an external file is not one of these — it opens externally — and a
    /// node standing for the document already on screen is not a link.
    func linkedDocumentURL(for node: FlowNode) -> URL? {
        guard let doc = document(for: node), doc.wraps == nil else { return nil }
        return doc.fileURL == documentURL ? nil : doc.fileURL
    }

    /// The title of the native document a node links to, for its Open
    /// command's label; `nil` when the node links nowhere native.
    func linkedDocumentTitle(for node: FlowNode) -> String? {
        guard linkedDocumentURL(for: node) != nil else { return nil }
        return document(for: node)?.title
    }

    /// The external file a node names, when its document is a sidecar
    /// wrapping one (a PDF above all). Resolved beside the sidecar first,
    /// then in the known roots — the community folder and the Reader
    /// library — so a wrapped file that only lives in Reader still opens.
    func externalFileURL(for node: FlowNode) -> URL? {
        guard let doc = document(for: node), let wraps = doc.wraps else { return nil }
        let beside = doc.fileURL.deletingLastPathComponent()
            .appendingPathComponent(wraps.file)
        if FileManager.default.fileExists(atPath: beside.path) { return beside }
        return locateInKnownRoots(named: (wraps.file as NSString).lastPathComponent)
    }

    /// Looks for a file by name in the folders Knowledge Space is allowed
    /// to read — the open community folder and the Reader library.
    private func locateInKnownRoots(named name: String) -> URL? {
        for base in [folderURL, readerLibraryURL].compactMap({ $0 }) {
            // The base itself and its PDF subfolder — the scan skips PDF/,
            // but a file named there is still found on demand.
            let roots = [base, base.appendingPathComponent(KnowledgeSpaceFolders.externalSubfolderName)]
            for root in roots {
                let candidate = root.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }

    /// The map the reader is looking at now, remembered before drilling in.
    private func currentTarget() -> OpenTarget? {
        if let url = documentURL { return .document(url) }
        if showingFolderMap { return .folder }
        return nil
    }

    /// Opens a node's linked native document in place, remembering where
    /// we came from so `goBack` can return. Triggered by the Open command
    /// inside the card — never by tapping the node itself.
    func openLinkedDocument(_ node: FlowNode) {
        guard let url = linkedDocumentURL(for: node) else { return }
        if let here = currentTarget() { navStack.append(here) }
        openDocument(url: url, keepingHistory: true)
    }

    /// Steps back out to the map we drilled in from.
    func goBack() {
        guard let target = navStack.popLast() else { return }
        switch target {
        case .folder:
            showFolderMap(keepingHistory: true)
        case .document(let url):
            openDocument(url: url, keepingHistory: true)
        }
    }

    /// Asks the controls window to hand a node's external file to another
    /// app. Triggered by the Open-in-Reader command inside the card.
    func requestExternalOpen(_ node: FlowNode) {
        guard let url = externalFileURL(for: node) else { return }
        externalOpenRequest = ExternalOpenRequest(url: url)
    }

    // MARK: - Writing notes in space

    /// The note the editor is changing, or nil when it composes a new one.
    /// Set before the editor window opens.
    private(set) var noteBeingEdited: LiquidDoc?

    /// The author name new notes carry, kept under the same default the
    /// other apps read. The editor offers to fill it when it is blank.
    var authorName: String {
        get { UserDefaults.standard.string(forKey: "authorName") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "authorName") }
    }

    /// The kinds a card in space can be edited as — the own-hand notes,
    /// not sources or citations, which are read here, not written.
    private static let editableNoteKinds: Set<String> = [
        LiquidDoc.DocumentType.note.rawValue,
        LiquidDoc.DocumentType.journal.rawValue,
        LiquidDoc.DocumentType.thought.rawValue,
        LiquidDoc.DocumentType.inspiration.rawValue,
    ]

    /// The writable note a node stands for, if any — so the card can offer
    /// Edit only where there is a note to edit.
    func editableNote(for node: FlowNode) -> LiquidDoc? {
        guard let doc = document(for: node) else { return nil }
        return Self.editableNoteKinds.contains(doc.documentType ?? "note") ? doc : nil
    }

    func prepareNewNote() { noteBeingEdited = nil }
    func prepareEditNote(_ doc: LiquidDoc) { noteBeingEdited = doc }

    /// Writes a composed or edited note into the community folder and
    /// refreshes the map. A new note mints an address per the format; an
    /// edit keeps identity, creation, place, and every other field,
    /// changing only the title, body, kind, and action the editor owns.
    @discardableResult
    func saveNote(title: String, bodyText: String, author: String,
                  kind: String, action: LiquidDoc.Action?) -> Bool {
        guard let folder = folderURL else {
            lastError = "Open a community folder first — the note lives there."
            return false
        }
        let trimmedAuthor = author.trimmingCharacters(in: .whitespaces)
        if !trimmedAuthor.isEmpty { authorName = trimmedAuthor }
        let name = trimmedAuthor.isEmpty ? "Unknown" : trimmedAuthor
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let finalTitle = trimmedTitle.isEmpty ? "Untitled" : trimmedTitle
        let body = LiquidDoc.parseBody(from: bodyText)
        let links = LiquidDoc.detectedLinks(in: body)

        var doc: LiquidDoc
        if let original = noteBeingEdited {
            doc = original
            doc.title = finalTitle
            doc.body = body
            doc.links = links
            doc.documentType = kind
            doc.action = action?.rawValue
        } else {
            let created = Date.now
            let id = LiquidAddress.makeID(author: name, created: created) { candidate in
                self.scannedDocs.contains { $0.id == candidate }
                    || FileManager.default.fileExists(atPath:
                        folder.appendingPathComponent(candidate)
                            .appendingPathExtension(LiquidDoc.fileExtension).path)
            }
            doc = LiquidDoc(format: LiquidDoc.knownFormat, id: id,
                            title: finalTitle, author: name, created: created,
                            body: body, links: links, wraps: nil,
                            action: action?.rawValue, documentType: kind,
                            fileURL: folder.appendingPathComponent(id)
                                .appendingPathExtension(LiquidDoc.fileExtension))
        }

        do {
            let accessing = folder.startAccessingSecurityScopedResource()
            defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
            try doc.jsonData().write(to: doc.fileURL, options: .atomic)
        } catch {
            lastError = "Could not save the note: \(error.localizedDescription)"
            return false
        }
        noteBeingEdited = nil
        rescanFolder()
        return true
    }

    // MARK: - Reader library

    /// Points Knowledge Space at the Reader library folder and remembers
    /// it by bookmark; its security scope stays open for the session so
    /// the files inside stay readable.
    func chooseReaderLibrary(url: URL) {
        if let previous = accessedReaderFolder {
            previous.stopAccessingSecurityScopedResource()
            accessedReaderFolder = nil
        }
        if url.startAccessingSecurityScopedResource() {
            accessedReaderFolder = url
        }
        readerLibraryURL = url
        if let bookmark = try? url.bookmarkData() {
            UserDefaults.standard.set(bookmark, forKey: Self.readerFolderBookmarkKey)
        }
    }

    /// Reopens the Reader library folder from its bookmark, once per
    /// session, reclaiming its security scope.
    func restoreReaderLibrary() {
        guard readerLibraryURL == nil,
              let bookmark = UserDefaults.standard.data(forKey: Self.readerFolderBookmarkKey)
        else { return }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) {
            if url.startAccessingSecurityScopedResource() { accessedReaderFolder = url }
            readerLibraryURL = url
        }
    }

    /// Whether the last session was already brought back, so the Library
    /// window reappearing later doesn't reload the map underneath.
    private var hasRestoredSession = false

    /// Reopens the last session's folder and document from their bookmarks.
    func reopenLastDocument() {
        guard !hasRestoredSession else { return }
        hasRestoredSession = true
        restoreReaderLibrary()
        if let bookmark = UserDefaults.standard.data(forKey: Self.folderBookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) {
                openFolder(url: url)
            }
        }
        guard let bookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) {
            openDocument(url: url)
        }
    }

    func save() {
        // The folder map's arrangement is the reader's own — it lives
        // locally, never written into the shared documents.
        if showingFolderMap {
            saveFolderLayout()
            return
        }
        guard let url = documentURL else { return }
        do {
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            try MapDocumentIO.save(
                KnowledgeMapDocument.Contents(flowDocument: engine.document, glossary: engine.glossary),
                to: url,
                format: documentFormat ?? .knowledgeSpaceJSON
            )
            hasUnsavedChanges = false
            lastError = nil
        } catch {
            lastError = "Save failed: \(error)"
        }
    }

    func closeDocument() {
        if documentURL != nil {
            save()
        }
        documentURL = nil
        documentFormat = nil
        documentTitle = "Map"
        showingFolderMap = false
        engine.load(document: FlowDocument(), glossary: nil)
        if folderURL != nil {
            showFolderMap()
        }
    }

    // MARK: - Direct manipulation

    /// Live drag update: positions change without touching the undo stack;
    /// `endDrag` commits one undoable move.
    func drag(node id: FlowNodeIdentifier, from start: NodePosition, viewDelta: SIMD3<Double>) {
        let delta = mapDelta(fromViewDelta: viewDelta)
        let position = NodePosition(x: start.x + CGFloat(delta.x),
                                    y: start.y + CGFloat(delta.y),
                                    z: start.z + CGFloat(delta.z))
        engine.document.layout.set(position: position, for: id)
        revision += 1
    }

    /// Commits a finished drag as one undoable move: positions rewind to
    /// their gesture-start anchors, then the move lands through the engine.
    func endDrag(nodes starts: [FlowNodeIdentifier: NodePosition]) {
        guard !starts.isEmpty else { return }
        var finals: [FlowNodeIdentifier: NodePosition] = [:]
        for (id, start) in starts {
            finals[id] = engine.position(of: id)
            engine.document.layout.set(position: start, for: id)
        }
        do {
            try engine.execute(.move(positions: finals))
        } catch {
            lastError = "\(error)"
        }
    }

    func toggleSelection(of id: FlowNodeIdentifier) {
        do {
            if engine.selection.contains(id) {
                try engine.execute(.removeFromSelection(ids: [id]))
            } else {
                try engine.execute(.addToSelection(ids: [id]))
            }
            // The original leaves focus with the last deselection.
            if engine.selection.isEmpty {
                isFocused = false
            }
        } catch {
            lastError = "\(error)"
        }
    }

    func run(_ command: MapCommand) {
        do {
            try engine.execute(command)
        } catch {
            lastError = "\(error)"
        }
    }

    // MARK: - AI agent

    private(set) var chat: [AgentChatEntry] = []
    private(set) var agentIsWorking = false
    private var agentSession: MapAgentSession?

    func sendToAgent(_ instruction: String, apiKey: String) {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !agentIsWorking else { return }
        guard !apiKey.isEmpty else {
            chat.append(AgentChatEntry(role: .activity, text: "Add your Anthropic API key in the field below first."))
            return
        }

        if agentSession == nil {
            agentSession = MapAgentSession(
                engine: engine,
                transport: AnthropicTransport(apiKeyProvider: { apiKey })
            )
        }

        chat.append(AgentChatEntry(role: .user, text: trimmed))
        agentIsWorking = true

        Task {
            do {
                _ = try await agentSession!.run(instruction: trimmed) { [weak self] event in
                    switch event {
                    case .assistantText(let text):
                        self?.chat.append(AgentChatEntry(role: .assistant, text: text))
                    case .toolCall(_, let summary):
                        self?.chat.append(AgentChatEntry(role: .activity, text: summary))
                    case .toolResult(let name, let result, let isError):
                        if isError {
                            self?.chat.append(AgentChatEntry(role: .activity, text: "\(name) failed: \(result)"))
                        }
                    }
                }
            } catch {
                chat.append(AgentChatEntry(role: .activity, text: "\(error)"))
            }
            agentIsWorking = false
        }
    }
}
#endif
