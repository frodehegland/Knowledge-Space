//
//  MapLayouts.swift
//  MapEngine
//
//  Alignment and distribution algorithms ported from CanvasView+Alignment,
//  generalized from x/y frames to any of the three axes. All functions are
//  pure: they compute new positions and leave mutation to MapCommand.move,
//  which handles undo.
//

import Foundation

public enum MapLayouts {

    /// Half the node's extent along an axis. Nodes are billboarded panels,
    /// so they have no depth: alignment on z works on centers alone.
    private static func halfExtent(of id: FlowNodeIdentifier, on axis: MapAxis, in engine: MapEngine) -> CGFloat {
        let size = engine.size(of: id)
        switch axis {
        case .x: return size.width / 2
        case .y: return size.height / 2
        case .z: return 0
        }
    }

    // MARK: - Alignment

    /// Ports leftAlign/rightAlign/topAlign/bottomAlign/center aligns:
    /// min/max alignment matches the smallest/largest edge; center alignment
    /// matches the average of centers.
    public static func align(_ ids: [FlowNodeIdentifier], on axis: MapAxis, to alignment: MapAlignment, in engine: MapEngine) throws -> [FlowNodeIdentifier: NodePosition] {
        guard ids.count >= 2 else {
            throw MapCommandError.invalidCommand("Alignment needs at least two nodes")
        }

        var result: [FlowNodeIdentifier: NodePosition] = [:]

        switch alignment {
        case .minEdge:
            let edge = ids.map { engine.position(of: $0).value(on: axis) - halfExtent(of: $0, on: axis, in: engine) }.min()!
            for id in ids {
                let center = edge + halfExtent(of: id, on: axis, in: engine)
                result[id] = engine.position(of: id).setting(center, on: axis)
            }

        case .maxEdge:
            let edge = ids.map { engine.position(of: $0).value(on: axis) + halfExtent(of: $0, on: axis, in: engine) }.max()!
            for id in ids {
                let center = edge - halfExtent(of: id, on: axis, in: engine)
                result[id] = engine.position(of: id).setting(center, on: axis)
            }

        case .center:
            let average = ids.map { engine.position(of: $0).value(on: axis) }.reduce(0, +) / CGFloat(ids.count)
            for id in ids {
                result[id] = engine.position(of: id).setting(average, on: axis)
            }
        }

        return result
    }

    // MARK: - Distribution

    /// Ports the distribute commands. `.evenly` spreads centers uniformly
    /// across the current span (first to last after sorting); `.spacing`
    /// packs nodes sequentially with a fixed gap between edges, like the
    /// Mac app's spacing distribution.
    public static func distribute(_ ids: [FlowNodeIdentifier], on axis: MapAxis, sort: MapDistributionSort, style: MapDistributionStyle, in engine: MapEngine) throws -> [FlowNodeIdentifier: NodePosition] {
        guard ids.count >= 2 else {
            throw MapCommandError.invalidCommand("Distribution needs at least two nodes")
        }

        let sorted = sortedIds(ids, on: axis, sort: sort, in: engine)
        var result: [FlowNodeIdentifier: NodePosition] = [:]

        switch style {
        case .evenly:
            let values = sorted.map { engine.position(of: $0).value(on: axis) }
            let minValue = values.min()!
            let maxValue = values.max()!
            let step = (maxValue - minValue) / CGFloat(sorted.count - 1)
            for (index, id) in sorted.enumerated() {
                let value = minValue + step * CGFloat(index)
                result[id] = engine.position(of: id).setting(value, on: axis)
            }

        case .spacing:
            let spacing: CGFloat = 10.0
            let first = sorted.first!
            var lastEdge = engine.position(of: first).value(on: axis) + halfExtent(of: first, on: axis, in: engine)
            result[first] = engine.position(of: first)
            for id in sorted.dropFirst() {
                let half = halfExtent(of: id, on: axis, in: engine)
                // Billboarded nodes have no z extent; keep a usable gap there.
                let gap = (axis == .z && half == 0) ? spacing * 5 : spacing
                let center = lastEdge + gap + half
                result[id] = engine.position(of: id).setting(center, on: axis)
                lastEdge = center + half
            }
        }

        return result
    }

    private static func sortedIds(_ ids: [FlowNodeIdentifier], on axis: MapAxis, sort: MapDistributionSort, in engine: MapEngine) -> [FlowNodeIdentifier] {
        func name(_ id: FlowNodeIdentifier) -> String {
            return engine.node(with: id)?.name ?? ""
        }
        func date(_ id: FlowNodeIdentifier) -> Date {
            return engine.node(with: id)?.glossaryEntry?.date ?? Date()
        }

        switch sort {
        case .standard:
            return ids.sorted { engine.position(of: $0).value(on: axis) < engine.position(of: $1).value(on: axis) }
        case .alphabetic:
            return ids.sorted { name($0) < name($1) }
        case .reverse:
            return ids.sorted { name($0) > name($1) }
        case .time:
            return ids.sorted { date($0) < date($1) }
        case .timeReverse:
            return ids.sorted { date($0) > date($1) }
        }
    }
}
