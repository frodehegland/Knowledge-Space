//
//  FlowNode.swift
//  MapEngine
//
//  Portable copy of LiquidAuthorTextCore's FlowNode. Codable behavior is
//  byte-compatible with documents written by Author for macOS, including the
//  legacy `title` fallback when decoding `name`.
//
//  Differences from the original:
//  - `citation: LACitation?` is not carried over (LACitation is a large
//    NSObject-based type). The map only needs `type == .citation`; rich
//    citation data can be attached later via `citationIdentifier`.
//

import Foundation

public typealias FlowNodeIdentifier = String

nonisolated public class FlowNode: Codable {

    public init(identifier: FlowNodeIdentifier = UUID().uuidString, title: String = "", definition: String? = nil, type: NodeType = .text, isStruckthrough: Bool = false, isHidden: Bool = false, documentPath: String? = nil, webLinkPath: String? = nil, internalLikUUID: String? = nil, collapsedNodes: [FlowNodeIdentifier] = []) {
        self.identifier = identifier
        self.name = title
        self.definition = definition
        self.type = type
        self.isStruckthrough = isStruckthrough
        self.isHidden = isHidden

        self.documentPath = documentPath
        self.webLinkPath = webLinkPath
        self.internalLinkId = internalLikUUID

        self.collapsedNodes = collapsedNodes
    }

    public enum CodingKeys: String, CodingKey {
        case identifier
        case title
        case name
        case type
        case definition
        case isStruckthrough
        case isHidden
        case documentPath
        case webLinkPath
        case internalLinkId
        case collapsedNodes
    }

    public var identifier: FlowNodeIdentifier = UUID().uuidString

    public var name: String = ""

    public var documentPath: String?
    public var webLinkPath: String?
    public var internalLinkId: String?

    public var definition: String?

    public var lowercasedTitle: String {
        return name.lowercased()
    }

    public var type: NodeType = .text

    public var isStruckthrough: Bool = false
    public var isHidden: Bool = false

    // Runtime-attached (not persisted with the node itself).
    public var containedHashTags: [String] = []
    public var glossaryEntry: GlossaryEntry?
    public var citationIdentifier: String?

    public var collapsedNodes: [FlowNodeIdentifier] = []

    required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        identifier = try container.decode(FlowNodeIdentifier.self, forKey: .identifier)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? container.decodeIfPresent(String.self, forKey: .title) ?? ""
        type = try container.decode(NodeType.self, forKey: .type)
        definition = try container.decodeIfPresent(String.self, forKey: .definition)
        isStruckthrough = try container.decode(Bool.self, forKey: .isStruckthrough)

        do {
            isHidden = try container.decode(Bool.self, forKey: .isHidden)
        } catch {
            isHidden = false
        }

        documentPath = try? container.decodeIfPresent(String.self, forKey: .documentPath)
        webLinkPath = try? container.decodeIfPresent(String.self, forKey: .webLinkPath)
        internalLinkId = try? container.decodeIfPresent(String.self, forKey: .internalLinkId)

        collapsedNodes = (try? container.decodeIfPresent([FlowNodeIdentifier].self, forKey: .collapsedNodes)) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(identifier, forKey: .identifier)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encode(definition, forKey: .definition)
        try container.encode(isStruckthrough, forKey: .isStruckthrough)
        try container.encodeIfPresent(isHidden, forKey: .isHidden)
        try container.encodeIfPresent(documentPath, forKey: .documentPath)
        try container.encodeIfPresent(webLinkPath, forKey: .webLinkPath)
        try container.encodeIfPresent(internalLinkId, forKey: .internalLinkId)
        try container.encodeIfPresent(collapsedNodes, forKey: .collapsedNodes)
    }
}

nonisolated public extension FlowNode {

    func node(with identifier: FlowNodeIdentifier, in nodeMap: FlowNodeMap) -> FlowNode? {
        return nodeMap[identifier]
    }
}

nonisolated extension FlowNode: Equatable {

    public static func ==(lhs: FlowNode, rhs: FlowNode) -> Bool {
        return ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
    }
}

nonisolated extension FlowNode: Hashable {

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self).hashValue)
    }
}

nonisolated extension FlowNode: CustomDebugStringConvertible {

    public var debugDescription: String {
        return "FlowNode: `\(name)`"
    }
}
