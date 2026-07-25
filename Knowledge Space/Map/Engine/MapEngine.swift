//
//  MapEngine.swift
//  MapEngine
//
//  Platform-neutral engine for Author's Map: owns the FlowDocument plus the
//  runtime state that lives in CanvasView/CanvasViewController on macOS
//  (selection, show filters, ignore-context flags), and executes MapCommand.
//
//  Renderers observe `onChange` and read positions/visibility from the
//  engine; they never mutate the document directly.
//

import Foundation

public final class MapEngine {

    public init(document: FlowDocument = FlowDocument(), glossary: Glossary? = nil) {
        self.document = document
        if let glossary {
            attach(glossary: glossary)
        }
    }

    // MARK: - State

    public private(set) var document: FlowDocument

    public private(set) var glossary: Glossary?

    public private(set) var selection: Set<FlowNodeIdentifier> = []

    /// Transient overlay on top of the document's visibility mode; mirrors
    /// the Mac app's Show menu (not persisted).
    public private(set) var showFilter: MapShowFilter = .none

    /// Mirrors the Mac app's "Select: ignore context" toggle (stored in
    /// UserDefaults there; engine state here).
    public private(set) var selectIgnoreContext: Bool = false
    public private(set) var showIgnoreContext: Bool = false

    /// Node content sizes, provided by the renderer once it has measured
    /// text. Layout commands fall back to an estimate for unmeasured nodes.
    public var nodeSizes: [FlowNodeIdentifier: CGSize] = [:]

    /// Called after any command changes state, with the identifiers whose
    /// visuals may need refreshing (empty means "reload everything").
    public var onChange: ((_ affectedNodeIds: [FlowNodeIdentifier]) -> Void)?

    private var undoStack: [MapCommand] = []
    private var redoStack: [MapCommand] = []

    // MARK: - Document access

    public func load(document: FlowDocument, glossary: Glossary?) {
        self.document = document
        self.selection = []
        self.showFilter = .none
        self.undoStack = []
        self.redoStack = []
        if let glossary {
            attach(glossary: glossary)
        } else {
            self.glossary = nil
        }
        onChange?([])
    }

    /// Attaches glossary entries to nodes by phrase, the runtime pairing the
    /// Mac app performs when it builds the Map.
    public func attach(glossary: Glossary) {
        self.glossary = glossary
        for node in document.nodes {
            node.glossaryEntry = glossary.entryMatching(term: node.name)
        }
    }

    public func node(with identifier: FlowNodeIdentifier) -> FlowNode? {
        return document.node(with: identifier)
    }

    public func position(of identifier: FlowNodeIdentifier) -> NodePosition {
        return document.layout.nodePositions[identifier] ?? NodePosition(x: 0, y: 0, z: 0)
    }

    public func size(of identifier: FlowNodeIdentifier) -> CGSize {
        if let size = nodeSizes[identifier] {
            return size
        }
        // Rough text-width estimate until the renderer reports real sizes.
        let title = node(with: identifier)?.name ?? ""
        return CGSize(width: max(80, CGFloat(title.count) * 9 + 24), height: 40)
    }

    public var selectedNodes: [FlowNode] {
        return document.nodes.filter { selection.contains($0.identifier) }
    }

    public var visibleNodes: [FlowNode] {
        return document.nodes.filter { isVisible($0) }
    }

    // MARK: - Visibility

    /// The effective glossary tag of a node. Untagged nodes count as
    /// "concept", matching the Mac app's selection and show behavior.
    public func effectiveTag(of node: FlowNode) -> String {
        let tag = node.glossaryEntry?.tagIdentifier ?? ""
        return tag.isEmpty ? "concept" : tag
    }

    /// Port of CanvasViewController's `canvasView(_:shouldShow:)` — the
    /// document-level visibility mode.
    public func shouldShow(_ node: FlowNode) -> Bool {
        let selectedCollapseNodes = selectedNodes.filter { $0.type == .collapse }
        let visibleCollapseMembers = selectedNodes.flatMap { $0.collapsedNodes }
        let allCollapsedMembers = document.nodes.flatMap { $0.collapsedNodes }

        switch document.settings.nodeVisibility {
        case .showOnlySections:
            return node.glossaryEntry?.tagIdentifier == "section"

        case .showOnlyCitations:
            return node.type == .citation

        case .showOnlyNotes:
            return node.type == .note || node.glossaryEntry?.tagIdentifier == "note"

        case .showOnlySelected:
            let connected = Set(connections(touchingSelection: true).flatMap { [$0.startNodeIdentifier, $0.endingNodeIdentifier] })
            let selectedAndConnected = selection.union(connected).union(visibleCollapseMembers)
            return selectedAndConnected.contains(node.identifier)

        case .showAll:
            guard document.nodes.contains(where: { $0.type == .collapse }) else {
                return true
            }
            if !selectedCollapseNodes.isEmpty {
                return selectedCollapseNodes.flatMap { $0.collapsedNodes }.contains(node.identifier)
                    || !allCollapsedMembers.contains(node.identifier)
            }
            return !Set(visibleCollapseMembers).intersection(allCollapsedMembers).isEmpty
                || !allCollapsedMembers.contains(node.identifier)
                || !Set(allCollapsedMembers).intersection(selection).isEmpty

        case .showOnlyConcepts:
            return node.glossaryEntry != nil
                && node.glossaryEntry?.tagIdentifier != "section"
                && node.type != .citation

        case .showConceptsAndCitations:
            if node.type == .citation { return true }
            if node.type == .note || node.glossaryEntry?.tagIdentifier == "note" { return false }
            return node.glossaryEntry != nil
                && node.glossaryEntry?.tagIdentifier != "section"

        case .showOnlyWithTags:
            return node.glossaryEntry?.tagIdentifier != nil

        case .showOnlyWithoutTags:
            guard let entry = node.glossaryEntry else { return true }
            return entry.tagIdentifier == nil

        case .individual:
            let hiddenTags = document.settings.hiddenTags
            guard let tagIdentifier = node.glossaryEntry?.tagIdentifier else {
                if node.type == .documentLink {
                    return !hiddenTags.contains("document")
                } else if node.type == .webLink {
                    return !hiddenTags.contains("weblink")
                }
                return node.type == .internalLink || !hiddenTags.contains("concept")
            }
            return !hiddenTags.contains(tagIdentifier)

        case .conceptsContainedInDocument:
            // Requires document text, which the engine does not hold. Hosts
            // that have the text can override via `documentContainsText`.
            guard node.glossaryEntry != nil else { return false }
            return documentContainsText?(node.name) ?? true
        }
    }

    /// Host-provided hook for the `.conceptsContainedInDocument` visibility
    /// mode, which needs the body text of the writing document.
    public var documentContainsText: ((String) -> Bool)?

    /// Full visibility: document mode + per-node hidden flag + transient
    /// show filter + ignore-context.
    public func isVisible(_ node: FlowNode) -> Bool {
        guard shouldShow(node) else { return false }

        if node.isHidden && !document.settings.shouldShowHiddenNodes {
            return false
        }

        let isContext = node.glossaryEntry?.isContext ?? false
        if showIgnoreContext && isContext {
            return false
        }

        switch showFilter {
        case .none:
            return true
        case .tag(let tag):
            return effectiveTag(of: node) == tag
        case .liked(let liked):
            return (node.glossaryEntry?.isLiked ?? false) == liked
        case .context:
            return isContext
        }
    }

    // MARK: - Connections

    /// Document connections touching the selection. When `touchingSelection`
    /// is false, returns all document connections.
    public func connections(touchingSelection: Bool) -> [FlowConnection] {
        guard touchingSelection else { return Array(document.connections) }
        return document.connections.filter { connection in
            selection.contains(connection.startNodeIdentifier) || selection.contains(connection.endingNodeIdentifier)
        }
    }

    // MARK: - Matching

    public func nodes(matching criteria: MapCriteria) -> [FlowNode] {
        var connectedIds: Set<FlowNodeIdentifier> = []
        if criteria.connectedToSelection == true {
            connectedIds = Set(connections(touchingSelection: true).flatMap { [$0.startNodeIdentifier, $0.endingNodeIdentifier] })
            connectedIds.formUnion(selectedNodes.flatMap { $0.collapsedNodes })
            connectedIds.subtract(selection)
        }

        return document.nodes.filter { node in
            if let tags = criteria.tagIdentifiers, !tags.contains(effectiveTag(of: node)) {
                return false
            }
            if let types = criteria.nodeTypes, !types.contains(node.type) {
                return false
            }
            if let liked = criteria.isLiked, (node.glossaryEntry?.isLiked ?? false) != liked {
                return false
            }
            if let context = criteria.isContext, (node.glossaryEntry?.isContext ?? false) != context {
                return false
            }
            if let hidden = criteria.isHidden, node.isHidden != hidden {
                return false
            }
            if let fragment = criteria.nameContains, !node.name.localizedCaseInsensitiveContains(fragment) {
                return false
            }
            if criteria.connectedToSelection == true, !connectedIds.contains(node.identifier) {
                return false
            }
            return true
        }
    }

    // MARK: - Undo

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    @discardableResult
    public func undo() throws -> MapCommandResult {
        guard let inverse = undoStack.popLast() else {
            throw MapCommandError.invalidCommand("Nothing to undo")
        }
        let result = try perform(inverse)
        if let redo = result.inverse {
            redoStack.append(redo)
        }
        return result
    }

    @discardableResult
    public func redo() throws -> MapCommandResult {
        guard let inverse = redoStack.popLast() else {
            throw MapCommandError.invalidCommand("Nothing to redo")
        }
        let result = try perform(inverse)
        if let undo = result.inverse {
            undoStack.append(undo)
        }
        return result
    }

    /// Executes a command, records its inverse for undo, and notifies the
    /// renderer.
    @discardableResult
    public func execute(_ command: MapCommand) throws -> MapCommandResult {
        let result = try perform(command)
        if let inverse = result.inverse {
            undoStack.append(inverse)
            redoStack.removeAll()
        }
        onChange?(result.affectedNodeIds)
        return result
    }

    // MARK: - Command execution

    private func perform(_ command: MapCommand) throws -> MapCommandResult {
        switch command {

        // MARK: Selection

        case .selectAll:
            let previous = Array(selection)
            let nodes = selectIgnoreContext
                ? document.nodes.filter { !($0.glossaryEntry?.isContext ?? false) }
                : Array(document.nodes)
            selection = Set(nodes.map { $0.identifier })
            return MapCommandResult(affectedNodeIds: Array(selection),
                                    message: "Selected all \(selection.count) nodes",
                                    inverse: .setSelection(ids: previous))

        case .deselectAll:
            let previous = Array(selection)
            selection = []
            return MapCommandResult(affectedNodeIds: previous,
                                    message: "Deselected all nodes",
                                    inverse: .setSelection(ids: previous))

        case .setSelection(let ids):
            let previous = Array(selection)
            selection = Set(try validated(ids))
            return MapCommandResult(affectedNodeIds: ids + previous,
                                    message: "Selected \(selection.count) nodes",
                                    inverse: .setSelection(ids: previous))

        case .addToSelection(let ids):
            let previous = Array(selection)
            selection.formUnion(try validated(ids))
            return MapCommandResult(affectedNodeIds: ids,
                                    message: "Added \(ids.count) nodes to the selection (\(selection.count) total)",
                                    inverse: .setSelection(ids: previous))

        case .removeFromSelection(let ids):
            let previous = Array(selection)
            selection.subtract(ids)
            return MapCommandResult(affectedNodeIds: ids,
                                    message: "Removed \(ids.count) nodes from the selection (\(selection.count) total)",
                                    inverse: .setSelection(ids: previous))

        case .selectByCriteria(let criteria, let extending):
            let previous = Array(selection)
            var matches = nodes(matching: criteria)
            if selectIgnoreContext && criteria.isContext == nil {
                matches = matches.filter { !($0.glossaryEntry?.isContext ?? false) }
            }
            let ids = Set(matches.map { $0.identifier })
            selection = extending ? selection.union(ids) : ids
            return MapCommandResult(affectedNodeIds: Array(ids) + previous,
                                    message: "Selected \(matches.count) matching nodes (\(selection.count) total)",
                                    inverse: .setSelection(ids: previous))

        case .selectSimilar:
            guard let reference = selectedNodes.first else {
                throw MapCommandError.emptySelection
            }
            let previous = Array(selection)
            let tag = reference.glossaryEntry?.tagIdentifier
            let similar = document.nodes.filter { $0.glossaryEntry?.tagIdentifier == tag }
            selection.formUnion(similar.map { $0.identifier })
            return MapCommandResult(affectedNodeIds: Array(selection),
                                    message: "Selected \(similar.count) nodes similar to '\(reference.name)'",
                                    inverse: .setSelection(ids: previous))

        case .selectConnected:
            let previous = Array(selection)
            let connected = nodes(matching: MapCriteria(connectedToSelection: true))
            selection = Set(connected.map { $0.identifier })
            return MapCommandResult(affectedNodeIds: Array(selection) + previous,
                                    message: "Selected \(selection.count) nodes connected to the previous selection",
                                    inverse: .setSelection(ids: previous))

        // MARK: Visibility

        case .setVisibilityMode(let mode):
            let previous = document.settings.nodeVisibility
            document.settings.nodeVisibility = mode
            return MapCommandResult(message: "Visibility mode set to \(mode.rawValue)",
                                    inverse: .setVisibilityMode(previous))

        case .setShowFilter(let filter):
            let previous = showFilter
            showFilter = filter
            return MapCommandResult(message: "Show filter set to \(filter)",
                                    inverse: .setShowFilter(previous))

        case .hide(let ids):
            for node in try validatedNodes(ids) {
                node.isHidden = true
            }
            selection.subtract(ids)
            return MapCommandResult(affectedNodeIds: ids,
                                    message: "Hid \(ids.count) nodes",
                                    inverse: .unhide(ids: ids))

        case .unhide(let ids):
            for node in try validatedNodes(ids) {
                node.isHidden = false
            }
            return MapCommandResult(affectedNodeIds: ids,
                                    message: "Unhid \(ids.count) nodes",
                                    inverse: .hide(ids: ids))

        case .toggleHiddenForSelection:
            let selected = selectedNodes
            guard !selected.isEmpty else { throw MapCommandError.emptySelection }
            let hidden = selected.filter { $0.isHidden }.map { $0.identifier }
            let visible = selected.filter { !$0.isHidden }.map { $0.identifier }
            // Mirrors SelectionManifest.prefersHidingSelection on macOS.
            if visible.count >= hidden.count {
                return try perform(.hide(ids: visible))
            }
            return try perform(.unhide(ids: hidden))

        case .setShouldShowHiddenNodes(let value):
            let previous = document.settings.shouldShowHiddenNodes
            document.settings.shouldShowHiddenNodes = value
            return MapCommandResult(message: value ? "Hidden nodes are now shown" : "Hidden nodes are now concealed",
                                    inverse: .setShouldShowHiddenNodes(previous))

        case .setHiddenTags(let tags):
            let previous = document.settings.hiddenTags
            document.settings.hiddenTags = tags
            document.settings.nodeVisibility = .individual
            return MapCommandResult(message: "Hidden tags set to \(tags.isEmpty ? "none" : tags.joined(separator: ", "))",
                                    inverse: .setHiddenTags(previous))

        case .setSelectIgnoreContext(let value):
            let previous = selectIgnoreContext
            selectIgnoreContext = value
            return MapCommandResult(message: "Select ignores context: \(value)",
                                    inverse: .setSelectIgnoreContext(previous))

        case .setShowIgnoreContext(let value):
            let previous = showIgnoreContext
            showIgnoreContext = value
            return MapCommandResult(message: "Show ignores context: \(value)",
                                    inverse: .setShowIgnoreContext(previous))

        // MARK: Movement & layout

        case .move(let positions):
            var previous: [FlowNodeIdentifier: NodePosition] = [:]
            for (id, position) in positions {
                guard node(with: id) != nil else { throw MapCommandError.unknownNode(id) }
                previous[id] = self.position(of: id)
                document.layout.set(position: position, for: id)
            }
            return MapCommandResult(affectedNodeIds: Array(positions.keys),
                                    message: "Moved \(positions.count) nodes",
                                    inverse: .move(positions: previous))

        case .moveBy(let ids, let dx, let dy, let dz):
            var positions: [FlowNodeIdentifier: NodePosition] = [:]
            for id in try validated(ids) {
                positions[id] = position(of: id).offset(dx: dx, dy: dy, dz: dz)
            }
            return try perform(.move(positions: positions))

        case .align(let axis, let alignment):
            let positions = try MapLayouts.align(targetIds(), on: axis, to: alignment, in: self)
            var result = try perform(.move(positions: positions))
            result.message = "Aligned \(positions.count) nodes (\(alignment.rawValue) on \(axis.rawValue))"
            return result

        case .distribute(let axis, let sort, let style):
            let positions = try MapLayouts.distribute(targetIds(), on: axis, sort: sort, style: style, in: self)
            var result = try perform(.move(positions: positions))
            result.message = "Distributed \(positions.count) nodes along \(axis.rawValue)"
            return result

        case .applyCustomLayout(let id):
            guard let custom = document.customLayouts.first(where: { $0.id == id || $0.name == id }) else {
                throw MapCommandError.unknownLayout(id)
            }
            let known = Set(document.nodes.map { $0.identifier })
            let positions = custom.layout.nodePositions.filter { known.contains($0.key) }
            var result = try perform(.move(positions: positions))
            result.message = "Applied layout '\(custom.name)' to \(positions.count) nodes"
            return result

        case .saveCustomLayout(let name):
            let custom = CustomLayout(name: name, layout: document.layout)
            document.customLayouts.append(custom)
            return MapCommandResult(message: "Saved current layout as '\(name)'",
                                    inverse: .deleteCustomLayout(id: custom.id))

        case .deleteCustomLayout(let id):
            guard let index = document.customLayouts.firstIndex(where: { $0.id == id || $0.name == id }) else {
                throw MapCommandError.unknownLayout(id)
            }
            let removed = document.customLayouts.remove(at: index)
            return MapCommandResult(message: "Deleted layout '\(removed.name)'")

        // MARK: Structure

        case .createNode(let title, let type, let position):
            let node = FlowNode(title: title, type: type)
            node.glossaryEntry = glossary?.entryMatching(term: title)
            document.nodes.insert(node)
            document.layout.set(position: position, for: node.identifier)
            return MapCommandResult(affectedNodeIds: [node.identifier],
                                    message: "Created \(type.rawValue) node '\(title)' (\(node.identifier))",
                                    inverse: .deleteNodes(ids: [node.identifier]))

        case .deleteNodes(let ids):
            let nodes = try validatedNodes(ids)
            let removedConnections = document.connections.filter { connection in
                ids.contains(connection.startNodeIdentifier) || ids.contains(connection.endingNodeIdentifier)
            }
            for node in nodes {
                document.nodes.remove(node)
                document.layout.removePosition(for: node.identifier)
            }
            document.connections.subtract(removedConnections)
            selection.subtract(ids)
            // Deleting is not losslessly invertible here (node metadata and
            // connections would need re-creation), so no inverse is offered.
            return MapCommandResult(affectedNodeIds: ids,
                                    message: "Deleted \(nodes.count) nodes and \(removedConnections.count) connections")

        case .renameNode(let id, let title):
            guard let node = node(with: id) else { throw MapCommandError.unknownNode(id) }
            let previous = node.name
            node.name = title
            node.glossaryEntry = glossary?.entryMatching(term: title)
            return MapCommandResult(affectedNodeIds: [id],
                                    message: "Renamed '\(previous)' to '\(title)'",
                                    inverse: .renameNode(id: id, title: previous))

        case .connect(let from, let to):
            guard node(with: from) != nil else { throw MapCommandError.unknownNode(from) }
            guard node(with: to) != nil else { throw MapCommandError.unknownNode(to) }
            guard from != to else { throw MapCommandError.invalidCommand("Cannot connect a node to itself") }
            if let existing = document.connections.first(where: { $0.startNodeIdentifier == from && $0.endingNodeIdentifier == to }) {
                return MapCommandResult(message: "Connection already exists (\(existing.identifier))")
            }
            let connection = FlowConnection(identifier: UUID().uuidString, endingNodeIdentifier: to, startNodeIdentifier: from)
            document.connections.insert(connection)
            return MapCommandResult(affectedNodeIds: [from, to],
                                    message: "Connected '\(node(with: from)?.name ?? from)' to '\(node(with: to)?.name ?? to)'",
                                    inverse: .disconnect(connectionIds: [connection.identifier]))

        case .disconnect(let connectionIds):
            let removed = document.connections.filter { connectionIds.contains($0.identifier) }
            guard !removed.isEmpty else {
                throw MapCommandError.invalidCommand("No connections found for the given identifiers")
            }
            document.connections.subtract(removed)
            let affected = removed.flatMap { [$0.startNodeIdentifier, $0.endingNodeIdentifier] }
            return MapCommandResult(affectedNodeIds: affected,
                                    message: "Removed \(removed.count) connections")

        case .setStruckthrough(let ids, let value):
            for node in try validatedNodes(ids) {
                node.isStruckthrough = value
            }
            return MapCommandResult(affectedNodeIds: ids,
                                    message: "\(value ? "Struck through" : "Unstruck") \(ids.count) nodes",
                                    inverse: .setStruckthrough(ids: ids, value: !value))

        // MARK: Glossary metadata

        case .setTag(let ids, let tagIdentifier):
            var affected: [FlowNodeIdentifier] = []
            for node in try validatedNodes(ids) {
                guard let entry = node.glossaryEntry else { continue }
                entry.tagIdentifier = tagIdentifier
                affected.append(node.identifier)
            }
            return MapCommandResult(affectedNodeIds: affected,
                                    message: "Tagged \(affected.count) nodes as '\(tagIdentifier)'")

        case .setLiked(let ids, let value):
            var affected: [FlowNodeIdentifier] = []
            for node in try validatedNodes(ids) {
                guard let entry = node.glossaryEntry else { continue }
                entry.isLiked = value
                affected.append(node.identifier)
            }
            return MapCommandResult(affectedNodeIds: affected,
                                    message: "\(value ? "Liked" : "Unliked") \(affected.count) nodes",
                                    inverse: .setLiked(ids: affected, value: !value))

        case .setContext(let ids, let value):
            var affected: [FlowNodeIdentifier] = []
            for node in try validatedNodes(ids) {
                guard let entry = node.glossaryEntry else { continue }
                entry.isContext = value
                affected.append(node.identifier)
            }
            return MapCommandResult(affectedNodeIds: affected,
                                    message: "Set context to \(value) on \(affected.count) nodes",
                                    inverse: .setContext(ids: affected, value: !value))
        }
    }

    // MARK: - Helpers

    /// Layout commands act on the selection; with nothing selected they act
    /// on all visible nodes so the AI can lay out a whole map in one call.
    private func targetIds() throws -> [FlowNodeIdentifier] {
        if !selection.isEmpty {
            return Array(selection)
        }
        let visible = visibleNodes.map { $0.identifier }
        guard !visible.isEmpty else { throw MapCommandError.emptySelection }
        return visible
    }

    private func validated(_ ids: [FlowNodeIdentifier]) throws -> [FlowNodeIdentifier] {
        for id in ids where node(with: id) == nil {
            throw MapCommandError.unknownNode(id)
        }
        return ids
    }

    private func validatedNodes(_ ids: [FlowNodeIdentifier]) throws -> [FlowNode] {
        return try ids.map {
            guard let node = node(with: $0) else { throw MapCommandError.unknownNode($0) }
            return node
        }
    }
}
