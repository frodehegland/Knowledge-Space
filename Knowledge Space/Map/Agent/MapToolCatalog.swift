//
//  MapToolCatalog.swift
//  MapAgent
//
//  The AI-facing tool surface over MapEngine. Each tool is an Anthropic
//  Messages API tool definition (name, description, input_schema) plus a
//  handler that turns the model's JSON input into MapCommand executions.
//
//  Anything a human can do on the Map is a tool by construction: the tools
//  map 1:1 onto the MapCommand API that the platform UI also uses.
//

import Foundation


public enum MapToolError: Error, CustomStringConvertible {
    case unknownTool(String)
    case badInput(String)

    public var description: String {
        switch self {
        case .unknownTool(let name):
            return "Unknown tool '\(name)'"
        case .badInput(let reason):
            return "Invalid tool input: \(reason)"
        }
    }
}

public struct MapToolCatalog {

    public init() {}

    /// Tool definitions in Anthropic Messages API format, ready to be
    /// serialized into the request's `tools` array.
    public var toolDefinitions: [[String: Any]] {
        let ids: [String: Any] = ["type": "array", "items": ["type": "string"], "description": "Node identifiers"]

        return [
            [
                "name": "get_map",
                "description": "Get the current state of the map: every node (id, title, type, tag, liked/context/hidden/selected/visible flags, x/y/z position, definition snippet), all connections, saved custom layouts, the visibility mode, and selection counts. Call this first to see what is on the map, and again after making changes if you need fresh positions.",
                "input_schema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "required": [] as [String]
                ]
            ],
            [
                "name": "select_nodes",
                "description": "Change the selection. mode 'all' selects everything, 'none' clears, 'ids' selects the given ids, 'criteria' selects nodes matching all provided criteria fields, 'similar' extends to nodes sharing the tag of the current selection, 'connected' selects nodes connected to the current selection. Tags include: concept, person, location, institution, event, issue, 'in progress', done, marked, product, reference, document, map, label, title, section, note. Untagged nodes count as 'concept'.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "mode": ["type": "string", "enum": ["all", "none", "ids", "criteria", "similar", "connected"]],
                        "ids": ids,
                        "extending": ["type": "boolean", "description": "Add to the current selection instead of replacing it"],
                        "tags": ["type": "array", "items": ["type": "string"], "description": "Criteria: glossary tag identifiers to match"],
                        "types": ["type": "array", "items": ["type": "string"], "description": "Criteria: node types (text, note, citation, documentLink, webLink, internalLink, collapse, map, ...)"],
                        "liked": ["type": "boolean", "description": "Criteria: liked state"],
                        "context": ["type": "boolean", "description": "Criteria: context state"],
                        "hidden": ["type": "boolean", "description": "Criteria: hidden state"],
                        "name_contains": ["type": "string", "description": "Criteria: case-insensitive substring of the title"]
                    ],
                    "required": ["mode"]
                ]
            ],
            [
                "name": "set_visibility",
                "description": "Control which nodes are shown. 'mode' sets the document-level visibility mode (showAll, showConceptsAndCitations, showOnlyConcepts, showOnlyCitations, showOnlyNotes, showOnlySections, showOnlySelected, showOnlyWithTags, showOnlyWithoutTags, individual). 'show_only_tag' overlays a transient filter showing only one tag ('' clears it). 'show_hidden' reveals or conceals nodes the user hid.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "mode": ["type": "string", "description": "Document visibility mode"],
                        "show_only_tag": ["type": "string", "description": "Transient filter: show only this tag; empty string clears the filter"],
                        "show_only_liked": ["type": "boolean", "description": "Transient filter: show only liked (true) or not-liked (false) nodes"],
                        "show_hidden": ["type": "boolean", "description": "Reveal user-hidden nodes"],
                        "hidden_tags": ["type": "array", "items": ["type": "string"], "description": "Tags to hide in 'individual' mode"]
                    ],
                    "required": [] as [String]
                ]
            ],
            [
                "name": "set_hidden",
                "description": "Hide or unhide specific nodes (the per-node hidden flag, persisted with the document).",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "ids": ids,
                        "hidden": ["type": "boolean"]
                    ],
                    "required": ["ids", "hidden"]
                ]
            ],
            [
                "name": "move_nodes",
                "description": "Move nodes. Provide either 'positions' (absolute x/y/z per node) or 'ids' + dx/dy/dz (relative offset). The map is planar in x/y; z extends into depth in Knowledge Space (positive z is toward the viewer). Nodes never rotate.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "positions": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "id": ["type": "string"],
                                    "x": ["type": "number"],
                                    "y": ["type": "number"],
                                    "z": ["type": "number"]
                                ],
                                "required": ["id", "x", "y"]
                            ]
                        ],
                        "ids": ids,
                        "dx": ["type": "number"],
                        "dy": ["type": "number"],
                        "dz": ["type": "number"]
                    ],
                    "required": [] as [String]
                ]
            ],
            [
                "name": "align_nodes",
                "description": "Align the selected nodes (or all visible nodes when nothing is selected) on one axis. 'minEdge' aligns left/top/near edges, 'center' aligns centers to their average, 'maxEdge' aligns right/bottom/far edges.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "axis": ["type": "string", "enum": ["x", "y", "z"]],
                        "alignment": ["type": "string", "enum": ["minEdge", "center", "maxEdge"]]
                    ],
                    "required": ["axis", "alignment"]
                ]
            ],
            [
                "name": "distribute_nodes",
                "description": "Distribute the selected nodes (or all visible nodes when nothing is selected) along one axis. sort: standard (current position), alphabetic, reverse, time (glossary date), timeReverse. style: 'evenly' spreads centers across the current span; 'spacing' packs nodes sequentially with a fixed gap.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "axis": ["type": "string", "enum": ["x", "y", "z"]],
                        "sort": ["type": "string", "enum": ["standard", "alphabetic", "reverse", "time", "timeReverse"]],
                        "style": ["type": "string", "enum": ["evenly", "spacing"]]
                    ],
                    "required": ["axis"]
                ]
            ],
            [
                "name": "create_node",
                "description": "Create a new node on the map at the given position.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "type": ["type": "string", "description": "Node type; default 'text'", "enum": ["text", "note", "label", "title", "heading", "citation", "documentLink", "webLink", "internalLink", "map", "collapse", "annotation", "bold", "italic"]],
                        "x": ["type": "number"],
                        "y": ["type": "number"],
                        "z": ["type": "number"]
                    ],
                    "required": ["title", "x", "y"]
                ]
            ],
            [
                "name": "delete_nodes",
                "description": "Delete nodes from the map, along with their connections. This cannot be undone — confirm with the user before deleting anything they did not explicitly ask to delete.",
                "input_schema": [
                    "type": "object",
                    "properties": ["ids": ids],
                    "required": ["ids"]
                ]
            ],
            [
                "name": "rename_node",
                "description": "Rename a node. The glossary entry is re-matched to the new title.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string"],
                        "title": ["type": "string"]
                    ],
                    "required": ["id", "title"]
                ]
            ],
            [
                "name": "connect_nodes",
                "description": "Create a connection between two nodes ('connect'), or remove connections by id ('disconnect').",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string", "enum": ["connect", "disconnect"]],
                        "from": ["type": "string", "description": "Start node id (connect)"],
                        "to": ["type": "string", "description": "End node id (connect)"],
                        "connection_ids": ["type": "array", "items": ["type": "string"], "description": "Connection ids (disconnect)"]
                    ],
                    "required": ["action"]
                ]
            ],
            [
                "name": "set_node_metadata",
                "description": "Set glossary metadata on nodes: tag (category), liked, context, or struckthrough. Only provided fields are changed.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "ids": ids,
                        "tag": ["type": "string"],
                        "liked": ["type": "boolean"],
                        "context": ["type": "boolean"],
                        "struckthrough": ["type": "boolean"]
                    ],
                    "required": ["ids"]
                ]
            ],
            [
                "name": "layouts",
                "description": "Manage saved layouts: 'save' stores the current node positions under a name, 'apply' restores a saved layout by name or id, 'delete' removes one. Use get_map to list saved layouts.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string", "enum": ["save", "apply", "delete"]],
                        "name": ["type": "string", "description": "Layout name (save) or name/id (apply, delete)"]
                    ],
                    "required": ["action", "name"]
                ]
            ],
            [
                "name": "undo_redo",
                "description": "Undo or redo the last map change.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string", "enum": ["undo", "redo"]]
                    ],
                    "required": ["action"]
                ]
            ]
        ]
    }

    /// Executes one tool call against the engine and returns the text to
    /// send back as the tool_result.
    public func execute(toolName: String, input: [String: Any], on engine: MapEngine) throws -> String {
        switch toolName {

        case "get_map":
            return try engine.manifest().jsonString()

        case "select_nodes":
            guard let mode = input["mode"] as? String else {
                throw MapToolError.badInput("select_nodes requires 'mode'")
            }
            switch mode {
            case "all":
                return try engine.execute(.selectAll).message
            case "none":
                return try engine.execute(.deselectAll).message
            case "ids":
                let ids = stringArray(input["ids"])
                if input["extending"] as? Bool == true {
                    return try engine.execute(.addToSelection(ids: ids)).message
                }
                return try engine.execute(.setSelection(ids: ids)).message
            case "similar":
                return try engine.execute(.selectSimilar).message
            case "connected":
                return try engine.execute(.selectConnected).message
            case "criteria":
                let criteria = MapCriteria(
                    tagIdentifiers: input["tags"].flatMap { stringArray($0).isEmpty ? nil : stringArray($0) },
                    nodeTypes: (input["types"] as? [String]).map { $0.compactMap { NodeType(rawValue: $0) } },
                    isLiked: input["liked"] as? Bool,
                    isContext: input["context"] as? Bool,
                    isHidden: input["hidden"] as? Bool,
                    nameContains: input["name_contains"] as? String
                )
                let extending = input["extending"] as? Bool ?? false
                return try engine.execute(.selectByCriteria(criteria: criteria, extending: extending)).message
            default:
                throw MapToolError.badInput("Unknown select mode '\(mode)'")
            }

        case "set_visibility":
            var messages: [String] = []
            if let modeString = input["mode"] as? String {
                guard let mode = FlowDocumentSettings.NodeVisibility(rawValue: modeString) else {
                    throw MapToolError.badInput("Unknown visibility mode '\(modeString)'")
                }
                messages.append(try engine.execute(.setVisibilityMode(mode)).message)
            }
            if let tag = input["show_only_tag"] as? String {
                let filter: MapShowFilter = tag.isEmpty ? .none : .tag(tag)
                messages.append(try engine.execute(.setShowFilter(filter)).message)
            }
            if let liked = input["show_only_liked"] as? Bool {
                messages.append(try engine.execute(.setShowFilter(.liked(liked))).message)
            }
            if let showHidden = input["show_hidden"] as? Bool {
                messages.append(try engine.execute(.setShouldShowHiddenNodes(showHidden)).message)
            }
            if let hiddenTags = input["hidden_tags"] as? [String] {
                messages.append(try engine.execute(.setHiddenTags(hiddenTags)).message)
            }
            guard !messages.isEmpty else {
                throw MapToolError.badInput("set_visibility requires at least one field")
            }
            return messages.joined(separator: "; ")

        case "set_hidden":
            let ids = stringArray(input["ids"])
            guard let hidden = input["hidden"] as? Bool else {
                throw MapToolError.badInput("set_hidden requires 'hidden'")
            }
            return try engine.execute(hidden ? .hide(ids: ids) : .unhide(ids: ids)).message

        case "move_nodes":
            if let positionsArray = input["positions"] as? [[String: Any]] {
                var positions: [FlowNodeIdentifier: NodePosition] = [:]
                for entry in positionsArray {
                    guard let id = entry["id"] as? String,
                          let x = cgFloat(entry["x"]), let y = cgFloat(entry["y"]) else {
                        throw MapToolError.badInput("Each position needs id, x, y")
                    }
                    positions[id] = NodePosition(x: x, y: y, z: cgFloat(entry["z"]) ?? engine.position(of: id).z)
                }
                return try engine.execute(.move(positions: positions)).message
            }
            let ids = stringArray(input["ids"])
            guard !ids.isEmpty else {
                throw MapToolError.badInput("move_nodes requires 'positions' or 'ids' with dx/dy/dz")
            }
            return try engine.execute(.moveBy(ids: ids,
                                              dx: cgFloat(input["dx"]) ?? 0,
                                              dy: cgFloat(input["dy"]) ?? 0,
                                              dz: cgFloat(input["dz"]) ?? 0)).message

        case "align_nodes":
            guard let axis = (input["axis"] as? String).flatMap(MapAxis.init(rawValue:)),
                  let alignment = (input["alignment"] as? String).flatMap(MapAlignment.init(rawValue:)) else {
                throw MapToolError.badInput("align_nodes requires 'axis' and 'alignment'")
            }
            return try engine.execute(.align(axis: axis, alignment: alignment)).message

        case "distribute_nodes":
            guard let axis = (input["axis"] as? String).flatMap(MapAxis.init(rawValue:)) else {
                throw MapToolError.badInput("distribute_nodes requires 'axis'")
            }
            let sort = (input["sort"] as? String).flatMap(MapDistributionSort.init(rawValue:)) ?? .standard
            let style = (input["style"] as? String).flatMap(MapDistributionStyle.init(rawValue:)) ?? .evenly
            return try engine.execute(.distribute(axis: axis, sort: sort, style: style)).message

        case "create_node":
            guard let title = input["title"] as? String,
                  let x = cgFloat(input["x"]), let y = cgFloat(input["y"]) else {
                throw MapToolError.badInput("create_node requires title, x, y")
            }
            let type = (input["type"] as? String).flatMap(NodeType.init(rawValue:)) ?? .text
            let position = NodePosition(x: x, y: y, z: cgFloat(input["z"]) ?? 0)
            return try engine.execute(.createNode(title: title, type: type, position: position)).message

        case "delete_nodes":
            return try engine.execute(.deleteNodes(ids: stringArray(input["ids"]))).message

        case "rename_node":
            guard let id = input["id"] as? String, let title = input["title"] as? String else {
                throw MapToolError.badInput("rename_node requires 'id' and 'title'")
            }
            return try engine.execute(.renameNode(id: id, title: title)).message

        case "connect_nodes":
            switch input["action"] as? String {
            case "connect":
                guard let from = input["from"] as? String, let to = input["to"] as? String else {
                    throw MapToolError.badInput("connect requires 'from' and 'to'")
                }
                return try engine.execute(.connect(from: from, to: to)).message
            case "disconnect":
                return try engine.execute(.disconnect(connectionIds: stringArray(input["connection_ids"]))).message
            default:
                throw MapToolError.badInput("connect_nodes requires action 'connect' or 'disconnect'")
            }

        case "set_node_metadata":
            let ids = stringArray(input["ids"])
            var messages: [String] = []
            if let tag = input["tag"] as? String {
                messages.append(try engine.execute(.setTag(ids: ids, tagIdentifier: tag)).message)
            }
            if let liked = input["liked"] as? Bool {
                messages.append(try engine.execute(.setLiked(ids: ids, value: liked)).message)
            }
            if let context = input["context"] as? Bool {
                messages.append(try engine.execute(.setContext(ids: ids, value: context)).message)
            }
            if let struck = input["struckthrough"] as? Bool {
                messages.append(try engine.execute(.setStruckthrough(ids: ids, value: struck)).message)
            }
            guard !messages.isEmpty else {
                throw MapToolError.badInput("set_node_metadata requires at least one of tag, liked, context, struckthrough")
            }
            return messages.joined(separator: "; ")

        case "layouts":
            guard let name = input["name"] as? String else {
                throw MapToolError.badInput("layouts requires 'name'")
            }
            switch input["action"] as? String {
            case "save":
                return try engine.execute(.saveCustomLayout(name: name)).message
            case "apply":
                return try engine.execute(.applyCustomLayout(id: name)).message
            case "delete":
                return try engine.execute(.deleteCustomLayout(id: name)).message
            default:
                throw MapToolError.badInput("layouts requires action save, apply, or delete")
            }

        case "undo_redo":
            switch input["action"] as? String {
            case "undo":
                return try engine.undo().message
            case "redo":
                return try engine.redo().message
            default:
                throw MapToolError.badInput("undo_redo requires action 'undo' or 'redo'")
            }

        default:
            throw MapToolError.unknownTool(toolName)
        }
    }

    // MARK: - Helpers

    private func stringArray(_ value: Any?) -> [String] {
        return value as? [String] ?? []
    }

    private func cgFloat(_ value: Any?) -> CGFloat? {
        if let double = value as? Double { return CGFloat(double) }
        if let int = value as? Int { return CGFloat(int) }
        return nil
    }
}
