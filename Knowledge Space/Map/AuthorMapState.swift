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

/// One document in the open community folder, listed by its own title.
struct FolderDocument: Identifiable {
    let url: URL
    let title: String
    var id: String { url.path }
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

    /// The community folder the picker granted, and the documents in it.
    private(set) var folderURL: URL?
    private(set) var folderDocuments: [FolderDocument] = []

    /// Whether the engine currently shows the folder itself as the map —
    /// every document a node, links between documents the threads.
    private(set) var showingFolderMap = false

    /// Bumped each time a different map loads, so the view can refit.
    private(set) var loadCount = 0

    /// The folder's decoded documents from the last scan, kept so the
    /// folder map can rebuild without re-reading every file.
    private var scannedDocs: [LiquidDoc] = []

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
        if let bookmark = try? url.bookmarkData() {
            UserDefaults.standard.set(bookmark, forKey: Self.folderBookmarkKey)
        }
        rescanFolder()
    }

    /// Lists the folder's documents the way the library scan does:
    /// recursively, skipping hidden files, asking iCloud to download
    /// placeholders it finds along the way. When no single document is
    /// open, the folder itself becomes the map.
    func rescanFolder() {
        guard let folder = folderURL else { return }
        LibraryScanner.requestICloudDownloads(in: folder)

        var docs: [LiquidDoc] = []
        var documents: [FolderDocument] = []
        if let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let url as URL in enumerator where LiquidDoc.isDocumentFile(url) {
                guard let data = try? Data(contentsOf: url),
                      let doc = try? LiquidDoc.decode(data: data, fileURL: url) else {
                    documents.append(FolderDocument(url: url, title: url.lastPathComponent))
                    continue
                }
                docs.append(doc)
                documents.append(FolderDocument(url: url, title: doc.title))
            }
        }
        scannedDocs = docs
        folderDocuments = documents.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }

        if documentURL == nil || showingFolderMap {
            showFolderMap()
        }
    }

    /// Loads the folder map into the engine: documents as nodes, links as
    /// threads, positions from the reader's saved arrangement.
    func showFolderMap() {
        guard let folder = folderURL, !scannedDocs.isEmpty else { return }
        if documentURL != nil, hasUnsavedChanges {
            save()
        }

        let contents = KnowledgeMapDocument.folderContents(documents: scannedDocs)
        applySavedFolderLayout(to: contents.flowDocument, folder: folder)
        engine.load(document: contents.flowDocument, glossary: contents.glossary)
        documentURL = nil
        documentFormat = nil
        documentTitle = folder.lastPathComponent
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

    func openDocument(url: URL) {
        do {
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

    /// Whether the last session was already brought back, so the Library
    /// window reappearing later doesn't reload the map underneath.
    private var hasRestoredSession = false

    /// Reopens the last session's folder and document from their bookmarks.
    func reopenLastDocument() {
        guard !hasRestoredSession else { return }
        hasRestoredSession = true
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
