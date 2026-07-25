//
//  NodePosition.swift
//  MapEngine
//
//  Portable copy of LiquidAuthorTextCore's NodePosition. Encodes as
//  {"x": …, "y": …, "z": …}; `z` is optional so pre-spatial documents
//  round-trip unchanged.
//

import Foundation

public struct NodePosition: Codable, Equatable {
    public let xConstant: CGFloat
    public let yConstant: CGFloat
    public let zConstant: CGFloat?

    public init(x: CGFloat, y: CGFloat, z: CGFloat? = 0) {
        xConstant = x
        yConstant = y
        zConstant = z
    }

    public var point: CGPoint {
        return CGPoint(x: xConstant, y: yConstant)
    }

    public var x: CGFloat { xConstant }
    public var y: CGFloat { yConstant }
    public var z: CGFloat { zConstant ?? 0 }

    public enum CodingKeys: String, CodingKey {
        case xConstant = "x"
        case yConstant = "y"
        case zConstant = "z"
    }
}

public extension NodePosition {

    func value(on axis: MapAxis) -> CGFloat {
        switch axis {
        case .x: return x
        case .y: return y
        case .z: return z
        }
    }

    func setting(_ value: CGFloat, on axis: MapAxis) -> NodePosition {
        switch axis {
        case .x: return NodePosition(x: value, y: y, z: z)
        case .y: return NodePosition(x: x, y: value, z: z)
        case .z: return NodePosition(x: x, y: y, z: value)
        }
    }

    func offset(dx: CGFloat = 0, dy: CGFloat = 0, dz: CGFloat = 0) -> NodePosition {
        return NodePosition(x: x + dx, y: y + dy, z: z + dz)
    }
}

/// The three spatial axes a map node can move along. The map is planar (x/y)
/// on macOS; Knowledge Space extends the same data into z. Nodes never rotate.
public enum MapAxis: String, Codable, CaseIterable {
    case x
    case y
    case z
}
