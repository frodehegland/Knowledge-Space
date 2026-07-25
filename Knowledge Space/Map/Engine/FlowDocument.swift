//
//  FlowDocument.swift
//  MapEngine
//
//  Portable copy of LiquidAuthorTextCore's FlowDocument. Codable behavior is
//  byte-compatible with documents written by Author for macOS, including
//  connection sanitizing and empty-node removal on decode.
//

import Foundation

public typealias FlowNodeMap = [FlowNodeIdentifier: FlowNode]

public class FlowDocument: Codable {

    public init(nodes: Set<FlowNode> = [], connections: Set<FlowConnection> = [], layout: CanvasViewLayout = CanvasViewLayout(), customLayouts: [CustomLayout] = [], settings: FlowDocumentSettings = FlowDocumentSettings()) {
        self.layout = layout
        self.customLayouts = customLayouts
        self.nodes = nodes
        self.connections = connections
        self.settings = settings
    }

    public var nodes: Set<FlowNode>
    public var connections: Set<FlowConnection>

    /// Removes junk connections accumulated by older versions of the app,
    /// which mistakenly persisted a copy of every transient (selection-driven)
    /// glossary connection. Keeps one connection per directed node pair.
    public static func sanitizedConnections(_ connections: Set<FlowConnection>) -> Set<FlowConnection> {
        var seenPairs = Set<[FlowConnectionIdentifier]>()
        var cleaned = Set<FlowConnection>()

        for connection in connections {
            guard connection.startNodeIdentifier != connection.endingNodeIdentifier else { continue }

            if seenPairs.insert([connection.startNodeIdentifier, connection.endingNodeIdentifier]).inserted {
                cleaned.insert(connection)
            }
        }

        return cleaned
    }

    public var layout: CanvasViewLayout

    public var customLayouts: [CustomLayout]

    public var settings: FlowDocumentSettings

    public var nodeMap: FlowNodeMap {
        return Dictionary(uniqueKeysWithValues: nodes.map { ($0.identifier, $0) })
    }

    public enum CodingKeys: String, CodingKey {
        case nodes
        case connections
        case layout
        case customLayouts
        case settings
    }

    required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodes = try container.decode(Set<FlowNode>.self, forKey: .nodes)
        connections = FlowDocument.sanitizedConnections(try container.decode(Set<FlowConnection>.self, forKey: .connections))
        layout = try container.decode(CanvasViewLayout.self, forKey: .layout)
        customLayouts = try container.decode([CustomLayout].self, forKey: .customLayouts)

        do {
            settings = try container.decode(FlowDocumentSettings.self, forKey: .settings)
        } catch {
            settings = FlowDocumentSettings()
        }

        removeEmpty()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.nodes, forKey: .nodes)
        try container.encode(self.connections, forKey: .connections)
        try container.encode(self.layout, forKey: .layout)
        try container.encode(self.customLayouts, forKey: .customLayouts)
        try container.encode(self.settings, forKey: .settings)
    }
}

public extension FlowDocument {

    func nodesWhere(predicate: (FlowNode) throws -> Bool) rethrows -> [FlowNode]? {
        return try nodes.filter(predicate)
    }

    func firstNodeMatching(title: String) -> FlowNode? {
        return nodes.first { $0.name == title }
    }

    func firstNodeContains(title: String) -> FlowNode? {
        return nodes.first { $0.name.contains(title) }
    }

    func node(with identifier: FlowNodeIdentifier) -> FlowNode? {
        return nodes.first { $0.identifier == identifier }
    }

    func removeEmpty() {
        for node in nodes {
            if node.name == "" {
                nodes.remove(node)
            }
        }
    }

    func append(_ flowDocument: FlowDocument) {
        flowDocument.nodes
            .filter { node in
                (self.nodesWhere(predicate: { $0.identifier == node.identifier }) ?? []).isEmpty
            }.forEach {
                self.nodes.insert($0)
            }

        // The macOS original inverts this condition, so merged connections
        // were never actually copied; here we copy the ones we don't have.
        flowDocument.connections
            .filter { conn in
                !self.connections.contains(where: { $0.identifier == conn.identifier })
            }
            .forEach {
                self.connections.insert($0)
            }

        self.layout.nodePositions.merge(flowDocument.layout.nodePositions) { old, _ in old }
    }
}
