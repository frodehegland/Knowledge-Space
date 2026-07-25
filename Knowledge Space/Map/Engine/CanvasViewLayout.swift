//
//  CanvasViewLayout.swift
//  MapEngine
//
//  Portable copy of LiquidAuthorTextCore's CanvasViewLayout/CustomLayout.
//  Encoding writes node positions as an array of {id, x, y, z} objects
//  (the "NewNodePosition" format); decoding also accepts the legacy
//  dictionary format for backwards compatibility.
//

import Foundation

public struct CustomLayout: Codable, Identifiable {

    public var id: String
    public var name: String
    public var layout: CanvasViewLayout

    public init(id: String = UUID().uuidString, name: String, layout: CanvasViewLayout) {
        self.id = id
        self.name = name
        self.layout = layout
    }
}

public struct CanvasViewLayout: Codable {

    public init(nodePositions: [FlowNodeIdentifier: NodePosition] = [:]) {
        self.nodePositions = nodePositions
    }

    public var nodePositions: [FlowNodeIdentifier: NodePosition] = [:]

    mutating public func set(position: NodePosition, for identifier: FlowNodeIdentifier) {
        nodePositions[identifier] = position
    }

    mutating public func removePosition(for identifier: FlowNodeIdentifier) {
        nodePositions.removeValue(forKey: identifier)
    }

    private enum CodingKeys: CodingKey {
        case nodePositions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // backwards compatibility with older documents
        if let arr = try? container.decodeIfPresent([NewNodePosition].self, forKey: .nodePositions) {
            self.nodePositions = [:]
            arr.forEach {
                self.nodePositions[$0.id] = NodePosition(x: $0.xConstant, y: $0.yConstant, z: $0.zConstant)
            }
        } else {
            self.nodePositions = try container.decode([FlowNodeIdentifier: NodePosition].self, forKey: .nodePositions)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        let array = nodePositions.keys.map {
            NewNodePosition(
                id: $0,
                x: nodePositions[$0]?.xConstant ?? .zero,
                y: nodePositions[$0]?.yConstant ?? .zero,
                z: nodePositions[$0]?.zConstant ?? .zero
            )
        }
        try container.encode(array, forKey: .nodePositions)
    }
}

public struct NewNodePosition: Codable {
    public let id: FlowNodeIdentifier
    public let xConstant: CGFloat
    public let yConstant: CGFloat
    public let zConstant: CGFloat?

    public init(id: FlowNodeIdentifier, x: CGFloat, y: CGFloat, z: CGFloat? = 0) {
        self.id = id
        self.xConstant = x
        self.yConstant = y
        self.zConstant = z
    }

    public var point: CGPoint {
        return CGPoint(x: xConstant, y: yConstant)
    }

    public enum CodingKeys: String, CodingKey {
        case id = "id"
        case xConstant = "x"
        case yConstant = "y"
        case zConstant = "z"
    }
}
