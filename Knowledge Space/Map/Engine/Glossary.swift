//
//  Glossary.swift
//  MapEngine
//
//  Portable copies of LiquidAuthorTextCore's Glossary, GlossaryEntry, and
//  GlossaryURL. Codable behavior is byte-compatible with glossary data
//  written by Author for macOS (including the legacy `entry` fallback when
//  decoding `description`, and `tag` as the wire key for `tagIdentifier`).
//
//  The AppKit-only helpers (NSMenuItem, TagsManager-backed `tag`) are not
//  carried over.
//

import Foundation

public typealias GlossaryIdentifier = String

public class Glossary: Codable {

    public init() {}

    /// Term should be lowercased to comparison
    public var entries: [GlossaryIdentifier: GlossaryEntry] = [:]
}

public extension Glossary {

    func add(_ entry: GlossaryEntry) {
        entries[entry.identifier] = entry
    }

    func remove(_ entry: GlossaryEntry) {
        entries.removeValue(forKey: entry.identifier)
    }

    func entryWith(identifier: GlossaryIdentifier) -> GlossaryEntry? {
        return entries[identifier]
    }

    /// First entry whose phrase (or one of its comma-separated phrase
    /// components) matches the term, case-insensitively.
    func entryMatching(term: String) -> GlossaryEntry? {
        let lowercased = term.lowercased()
        return entries.values.first { entry in
            if entry.phrase.lowercased() == lowercased { return true }
            return entry.phraseComponents.contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == lowercased }
        }
    }
}

public class GlossaryEntry: Codable {

    public init(
        identifier: GlossaryIdentifier,
        phrase: String,
        entry: String,
        type: String? = nil,
        urls: [GlossaryURL] = [],
        internalLinkId: String? = nil,
        headingNote: String? = nil,
        documentPath: String? = nil,
        citationIdentifiers: [String] = [],
        tagIdentifier: String = "",
        date: Date = Date(),
        isLiked: Bool = false,
        isContext: Bool = false,
        position: NodePosition? = nil
    ) {
        self.identifier = identifier
        self.phrase = phrase
        self.description = entry
        self.type = type
        self.urls = urls
        self.internalLinkId = internalLinkId
        self.headingNote = headingNote
        self.documentPath = documentPath
        self.citationIdentifiers = citationIdentifiers
        self.tagIdentifier = tagIdentifier
        self.date = date
        self.isLiked = isLiked
        self.isContext = isContext
        self.position = position
    }

    required public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try container.decode(String.self, forKey: .identifier)
        phrase = try container.decode(String.self, forKey: .phrase)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? container.decodeIfPresent(String.self, forKey: .entry) ?? ""
        type = try container.decodeIfPresent(String.self, forKey: .type)
        internalLinkId = try container.decodeIfPresent(String.self, forKey: .internalLinkId)
        headingNote = try container.decodeIfPresent(String.self, forKey: .headingNote)
        urls = try container.decodeIfPresent([GlossaryURL].self, forKey: .urls) ?? []
        documentPath = try container.decodeIfPresent(String.self, forKey: .documentPath)
        citationIdentifiers = try container.decodeIfPresent([String].self, forKey: .citationIdentifiers) ?? []
        tagIdentifier = try container.decodeIfPresent(String.self, forKey: .tagIdentifier) ?? ""
        date = try container.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        isLiked = try container.decodeIfPresent(Bool.self, forKey: .isLiked) ?? false
        isContext = try container.decodeIfPresent(Bool.self, forKey: .isContext) ?? false
        position = try container.decodeIfPresent(NodePosition.self, forKey: .position)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(identifier, forKey: .identifier)
        try container.encode(phrase, forKey: .phrase)
        try container.encode(description, forKey: .description)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(urls, forKey: .urls)
        try container.encodeIfPresent(internalLinkId, forKey: .internalLinkId)
        try container.encodeIfPresent(headingNote, forKey: .headingNote)
        try container.encodeIfPresent(documentPath, forKey: .documentPath)
        try container.encodeIfPresent(citationIdentifiers, forKey: .citationIdentifiers)
        try container.encodeIfPresent(tagIdentifier, forKey: .tagIdentifier)
        try container.encodeIfPresent(date, forKey: .date)
        try container.encodeIfPresent(isLiked, forKey: .isLiked)
        try container.encodeIfPresent(isContext, forKey: .isContext)
        try container.encodeIfPresent(position, forKey: .position)
    }

    public let identifier: GlossaryIdentifier

    public var phrase: String
    public var description: String
    public var type: String?

    public var urls: [GlossaryURL] = []
    public var internalLinkId: String?
    public var headingNote: String?
    public var documentPath: String?
    public var citationIdentifiers: [String]? = []
    public var isSaved: Bool = false

    public var tagIdentifier: String? = ""

    public var date: Date = Date()

    public var isLiked: Bool = false
    public var isContext: Bool = false

    public var position: NodePosition?

    enum CodingKeys: String, CodingKey {
        case identifier
        case phrase
        case entry
        case description
        case type
        case urls
        case internalLinkId
        case headingNote
        case documentPath
        case citationIdentifiers
        case tagIdentifier = "tag"
        case date
        case isLiked
        case isContext
        case position
    }
}

public extension GlossaryEntry {

    var name: String {
        return phrase
    }

    var phraseComponents: [String] {
        return phrase.components(separatedBy: ",")
    }

    var entryComponents: [String] {
        return description.components(separatedBy: ",")
    }
}

public class GlossaryURL: Codable {

    public init(description: String? = nil, url: String) {
        self.description = description
        self.url = url
    }

    public var description: String?
    public var url: String
}
