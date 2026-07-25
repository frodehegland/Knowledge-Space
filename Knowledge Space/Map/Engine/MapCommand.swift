//
//  MapCommand.swift
//  MapEngine
//
//  Every user-visible Map operation expressed as a typed, Codable command.
//  Three clients drive this API: platform UI (gestures/menus), the AI agent
//  (tool calls map 1:1 onto commands), and undo (execution returns an
//  inverse command where one exists).
//

import Foundation

// MARK: - Supporting types

/// Criteria-based selection and filtering. All populated fields must match
/// (logical AND). Mirrors and extends the Mac app's Select menu, which
/// selects by glossary tag ("concept", "person", "location", …), liked
/// state, and context state.
public struct MapCriteria: Codable, Equatable {

    public init(tagIdentifiers: [String]? = nil, nodeTypes: [NodeType]? = nil, isLiked: Bool? = nil, isContext: Bool? = nil, isHidden: Bool? = nil, nameContains: String? = nil, connectedToSelection: Bool? = nil) {
        self.tagIdentifiers = tagIdentifiers
        self.nodeTypes = nodeTypes
        self.isLiked = isLiked
        self.isContext = isContext
        self.isHidden = isHidden
        self.nameContains = nameContains
        self.connectedToSelection = connectedToSelection
    }

    /// Glossary tag identifiers, e.g. "concept", "person", "location",
    /// "institution", "event", "issue", "in progress", "done", "marked",
    /// "product", "reference", "document", "map", "label", "title",
    /// "section", "note". Nodes without a glossary tag count as "concept",
    /// matching the Mac app.
    public var tagIdentifiers: [String]?

    public var nodeTypes: [NodeType]?
    public var isLiked: Bool?
    public var isContext: Bool?
    public var isHidden: Bool?

    /// Case-insensitive substring match on the node title.
    public var nameContains: String?

    /// Restrict to nodes connected to the current selection.
    public var connectedToSelection: Bool?
}

/// Transient show filter layered on top of the document's visibility mode,
/// mirroring the Mac app's Show menu (show only one tag, only liked, only
/// context…). Not persisted.
public enum MapShowFilter: Codable, Equatable {
    case none
    case tag(String)
    case liked(Bool)
    case context
}

public enum MapAlignment: String, Codable {
    /// Align to the smallest edge on the axis (left/top/near).
    case minEdge
    /// Align centers to their average.
    case center
    /// Align to the largest edge on the axis (right/bottom/far).
    case maxEdge
}

public enum MapDistributionSort: String, Codable {
    case standard
    case alphabetic
    case reverse
    case time
    case timeReverse
}

public enum MapDistributionStyle: String, Codable {
    /// Spread centers evenly across the current span (first to last).
    case evenly
    /// Pack nodes sequentially with fixed spacing between edges.
    case spacing
}

// MARK: - Commands

public enum MapCommand: Codable {

    // Selection
    case selectAll
    case deselectAll
    case setSelection(ids: [FlowNodeIdentifier])
    case addToSelection(ids: [FlowNodeIdentifier])
    case removeFromSelection(ids: [FlowNodeIdentifier])
    case selectByCriteria(criteria: MapCriteria, extending: Bool)
    /// Select all nodes sharing the tag of the currently selected node.
    case selectSimilar
    /// Extend the selection with nodes connected to it (including collapsed
    /// members of selected collapse nodes).
    case selectConnected

    // Visibility
    case setVisibilityMode(FlowDocumentSettings.NodeVisibility)
    case setShowFilter(MapShowFilter)
    case hide(ids: [FlowNodeIdentifier])
    case unhide(ids: [FlowNodeIdentifier])
    /// Hide the visible part of the selection, or unhide the hidden part,
    /// whichever is larger — mirrors the Mac app's toggle.
    case toggleHiddenForSelection
    case setShouldShowHiddenNodes(Bool)
    case setHiddenTags([String])
    case setSelectIgnoreContext(Bool)
    case setShowIgnoreContext(Bool)

    // Movement & layout
    case move(positions: [FlowNodeIdentifier: NodePosition])
    case moveBy(ids: [FlowNodeIdentifier], dx: CGFloat, dy: CGFloat, dz: CGFloat)
    case align(axis: MapAxis, alignment: MapAlignment)
    case distribute(axis: MapAxis, sort: MapDistributionSort, style: MapDistributionStyle)
    case applyCustomLayout(id: String)
    case saveCustomLayout(name: String)
    case deleteCustomLayout(id: String)

    // Structure
    case createNode(title: String, type: NodeType, position: NodePosition)
    case deleteNodes(ids: [FlowNodeIdentifier])
    case renameNode(id: FlowNodeIdentifier, title: String)
    case connect(from: FlowNodeIdentifier, to: FlowNodeIdentifier)
    case disconnect(connectionIds: [FlowConnectionIdentifier])
    case setStruckthrough(ids: [FlowNodeIdentifier], value: Bool)

    // Glossary metadata
    case setTag(ids: [FlowNodeIdentifier], tagIdentifier: String)
    case setLiked(ids: [FlowNodeIdentifier], value: Bool)
    case setContext(ids: [FlowNodeIdentifier], value: Bool)
}

// MARK: - Result

public struct MapCommandResult {

    public init(affectedNodeIds: [FlowNodeIdentifier] = [], message: String, inverse: MapCommand? = nil) {
        self.affectedNodeIds = affectedNodeIds
        self.message = message
        self.inverse = inverse
    }

    public var affectedNodeIds: [FlowNodeIdentifier]

    /// Human/AI-readable description of what happened, e.g.
    /// "Selected 12 nodes tagged 'person'".
    public var message: String

    /// Command that undoes this one, when the operation is invertible.
    public var inverse: MapCommand?
}

public enum MapCommandError: Error, CustomStringConvertible {
    case unknownNode(FlowNodeIdentifier)
    case unknownLayout(String)
    case emptySelection
    case invalidCommand(String)

    public var description: String {
        switch self {
        case .unknownNode(let id):
            return "No node with identifier '\(id)'"
        case .unknownLayout(let id):
            return "No custom layout named or identified by '\(id)'"
        case .emptySelection:
            return "This command requires a selection, but nothing is selected"
        case .invalidCommand(let reason):
            return reason
        }
    }
}
