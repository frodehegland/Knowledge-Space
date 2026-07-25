//
//  FlowDocumentSettings.swift
//  MapEngine
//
//  Portable copy of LiquidAuthorTextCore's FlowDocumentSettings.
//
//  Note: the original decodes `showOnlyTagTitle` with the wrong coding key
//  (`.shouldShowHiddenNodes`), which makes decoding throw on every document
//  and FlowDocument silently falls back to default settings. This copy uses
//  the correct key, so settings actually round-trip.
//

import Foundation

public class FlowDocumentSettings: Codable {

    public enum NodeVisibility: String, Codable {
        /// Shows tags not excluded by the `hiddenTags` property.
        case individual

        /// Shows all nodes with `isHidden` set to `false`.
        case showAll

        /// Shows only nodes containing a tag.
        case showOnlyWithTags

        /// Shows only nodes not containing a tag.
        case showOnlyWithoutTags

        /// Shows only nodes with titles matching concepts contained in the document
        case conceptsContainedInDocument

        /// hides all non selected nodes, but also shows selected nodes which are connected
        case showOnlySelected

        case showOnlySections

        case showOnlyCitations

        case showOnlyNotes

        case showOnlyConcepts

        /// The Map default: defined concepts plus citations (no sections, no notes).
        case showConceptsAndCitations
    }

    public init(shouldShowHiddenNodes: Bool = false) {
        self.shouldShowHiddenNodes = shouldShowHiddenNodes
    }

    public var shouldShowHiddenNodes: Bool = false

    public var showOnlyTagTitle: String? = nil

    public var hiddenTags: [String] = []

    public var nodeVisibility: NodeVisibility = .showAll

    public enum CodingKeys: String, CodingKey {
        case shouldShowHiddenNodes
        case showOnlyTagTitle
        case hiddenTags
        case nodeVisibility
    }

    required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        shouldShowHiddenNodes = try container.decode(Bool.self, forKey: .shouldShowHiddenNodes)
        showOnlyTagTitle = try container.decodeIfPresent(String.self, forKey: .showOnlyTagTitle)
        hiddenTags = try container.decodeIfPresent([String].self, forKey: .hiddenTags) ?? []
        nodeVisibility = try container.decodeIfPresent(NodeVisibility.self, forKey: .nodeVisibility) ?? .showAll
    }
}
