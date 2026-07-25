//
//  NodeType.swift
//  MapEngine
//
//  Portable copy of LiquidAuthorTextCore's NodeType. The raw values are part
//  of the persisted FlowDocument format and must not change.
//

import Foundation

public enum NodeType: String, Codable {
    case collapse
    case text
    case note
    case title
    case label
    case heading
    case annotation
    case bold
    case italic
    case documentLink
    case webLink
    case citation
    case internalLink
    case map

    /// Lenient factory used when migrating legacy documents: unknown raw
    /// values become `.text` instead of failing.
    public static func build(rawValue: String) -> NodeType {
        return NodeType(rawValue: rawValue) ?? .text
    }
}
