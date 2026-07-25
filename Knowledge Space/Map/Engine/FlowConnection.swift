//
//  FlowConnection.swift
//  MapEngine
//
//  Portable copy of LiquidAuthorTextCore's FlowConnection. Codable behavior
//  is byte-compatible with documents written by Author for macOS.
//

import Foundation

public typealias FlowConnectionIdentifier = String

nonisolated public struct FlowConnection: Hashable, Codable {

    public init(identifier: FlowConnectionIdentifier, endingNodeIdentifier: FlowConnectionIdentifier, startNodeIdentifier: FlowConnectionIdentifier, lightweight: Bool = false) {
        self.identifier = identifier
        self.endingNodeIdentifier = endingNodeIdentifier
        self.startNodeIdentifier = startNodeIdentifier
        self.lightweight = lightweight
    }

    public let identifier: FlowConnectionIdentifier

    public let endingNodeIdentifier: FlowConnectionIdentifier

    public let startNodeIdentifier: FlowConnectionIdentifier

    public enum CodingKeys: String, CodingKey {
        case identifier
        case endingNodeIdentifier
        case startNodeIdentifier
    }

    public let lightweight: Bool

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try values.decode(FlowConnectionIdentifier.self, forKey: .identifier)
        endingNodeIdentifier = try values.decode(FlowConnectionIdentifier.self, forKey: .endingNodeIdentifier)
        startNodeIdentifier = try values.decode(FlowConnectionIdentifier.self, forKey: .startNodeIdentifier)
        lightweight = false
    }
}

nonisolated public extension FlowConnection {

    /// True if this connection touches the given node.
    func involves(_ identifier: FlowNodeIdentifier) -> Bool {
        return startNodeIdentifier == identifier || endingNodeIdentifier == identifier
    }

    /// The node on the other end of the connection, if `identifier` is one of
    /// the endpoints.
    func opposite(of identifier: FlowNodeIdentifier) -> FlowNodeIdentifier? {
        if startNodeIdentifier == identifier { return endingNodeIdentifier }
        if endingNodeIdentifier == identifier { return startNodeIdentifier }
        return nil
    }
}
