//
//  MapManifest.swift
//  MapEngine
//
//  A JSON-serializable snapshot of the map, designed to be handed to the AI
//  agent as context (and usable by any observer). Ports and extends the Mac
//  app's SelectionManifest.
//

import Foundation

public struct MapManifest: Codable {

    public struct NodeInfo: Codable {
        public var id: FlowNodeIdentifier
        public var title: String
        public var type: String
        public var tag: String
        public var isLiked: Bool
        public var isContext: Bool
        public var isHidden: Bool
        public var isSelected: Bool
        public var isVisible: Bool
        public var x: CGFloat
        public var y: CGFloat
        public var z: CGFloat
        /// First 200 characters of the glossary definition, when present.
        public var definition: String?
    }

    public struct ConnectionInfo: Codable {
        public var id: FlowConnectionIdentifier
        public var from: FlowNodeIdentifier
        public var to: FlowNodeIdentifier
    }

    public struct LayoutInfo: Codable {
        public var id: String
        public var name: String
    }

    public var nodes: [NodeInfo]
    public var connections: [ConnectionInfo]
    public var customLayouts: [LayoutInfo]
    public var visibilityMode: String
    public var selectedCount: Int
    public var visibleCount: Int
    public var hiddenCount: Int

    public func jsonString(prettyPrinted: Bool = false) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        let data = try encoder.encode(self)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

public extension MapEngine {

    /// Snapshot of the whole map for the AI agent or any observer.
    func manifest() -> MapManifest {
        let sortedNodes = document.nodes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let nodeInfos = sortedNodes.map { node -> MapManifest.NodeInfo in
            let position = position(of: node.identifier)
            let entry = node.glossaryEntry
            var definition = entry?.description ?? node.definition
            if let full = definition, full.count > 200 {
                definition = String(full.prefix(200))
            }

            return MapManifest.NodeInfo(
                id: node.identifier,
                title: node.name,
                type: node.type.rawValue,
                tag: effectiveTag(of: node),
                isLiked: entry?.isLiked ?? false,
                isContext: entry?.isContext ?? false,
                isHidden: node.isHidden,
                isSelected: selection.contains(node.identifier),
                isVisible: isVisible(node),
                x: position.x,
                y: position.y,
                z: position.z,
                definition: definition
            )
        }

        let connectionInfos = document.connections.map {
            MapManifest.ConnectionInfo(id: $0.identifier, from: $0.startNodeIdentifier, to: $0.endingNodeIdentifier)
        }.sorted { $0.id < $1.id }

        let layoutInfos = document.customLayouts.map {
            MapManifest.LayoutInfo(id: $0.id, name: $0.name)
        }

        return MapManifest(
            nodes: nodeInfos,
            connections: connectionInfos,
            customLayouts: layoutInfos,
            visibilityMode: document.settings.nodeVisibility.rawValue,
            selectedCount: selection.count,
            visibleCount: nodeInfos.filter { $0.isVisible }.count,
            hiddenCount: nodeInfos.filter { $0.isHidden }.count
        )
    }
}
