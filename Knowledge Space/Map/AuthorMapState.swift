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

    /// The open document's own title, read from its JSON on open.
    private(set) var documentTitle = "Map"

    // MARK: - View transform (map points <-> volume points)

    /// Map coordinates are Author canvas points (y down, origin roughly at
    /// the canvas center). The volume shows them scaled to fit; z passes
    /// through the same scale, so depth reads in proportion.
    private(set) var mapScale: Double = 1.0
    private(set) var mapCenter = SIMD2<Double>(0, 0)

    func viewPosition(of node: FlowNode, in size: CGSize) -> SIMD3<Double> {
        let position = engine.position(of: node.identifier)
        return SIMD3(
            (Double(position.x) - mapCenter.x) * mapScale + size.width / 2,
            (Double(position.y) - mapCenter.y) * mapScale + size.height / 2,
            Double(position.z) * mapScale
        )
    }

    func mapDelta(fromViewDelta delta: SIMD3<Double>) -> SIMD3<Double> {
        guard mapScale > 0 else { return .zero }
        return delta / mapScale
    }

    /// Fits the visible nodes into the given view size with padding.
    func fit(in size: CGSize) {
        let positions = engine.visibleNodes.map { engine.position(of: $0.identifier) }
        guard !positions.isEmpty else {
            mapScale = 1
            mapCenter = .zero
            return
        }

        let xs = positions.map { Double($0.x) }
        let ys = positions.map { Double($0.y) }
        let minX = xs.min()!, maxX = xs.max()!
        let minY = ys.min()!, maxY = ys.max()!

        mapCenter = SIMD2((minX + maxX) / 2, (minY + maxY) / 2)

        let padding = 260.0
        let spanX = max(maxX - minX + padding, 1)
        let spanY = max(maxY - minY + padding, 1)
        mapScale = min(size.width / spanX, size.height / spanY, 1.25)
    }

    // MARK: - Document lifecycle

    private static let bookmarkKey = "knowledgeMapDocumentBookmark"

    init() {
        engine.onChange = { [weak self] _ in
            self?.revision += 1
            self?.hasUnsavedChanges = true
        }
    }

    func open(url: URL) {
        do {
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }

            let contents = try KnowledgeMapDocument.load(from: url)
            engine.load(document: contents.flowDocument, glossary: contents.glossary)
            documentURL = url
            documentTitle = contents.title ?? url.lastPathComponent
            hasUnsavedChanges = false
            lastError = nil
            agentSession?.clearHistory()

            if let bookmark = try? url.bookmarkData() {
                UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
            }
        } catch {
            lastError = "\(error)"
        }
    }

    /// Reopens the document from the last session's bookmark.
    func reopenLastDocument() {
        guard let bookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) {
            open(url: url)
        }
    }

    func save() {
        guard let url = documentURL else { return }
        do {
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            try KnowledgeMapDocument.save(
                KnowledgeMapDocument.Contents(flowDocument: engine.document, glossary: engine.glossary),
                to: url
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
        documentTitle = "Map"
        engine.load(document: FlowDocument(), glossary: nil)
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

    func endDrag(node id: FlowNodeIdentifier, from start: NodePosition) {
        let final = engine.position(of: id)
        engine.document.layout.set(position: start, for: id)
        do {
            try engine.execute(.move(positions: [id: final]))
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
