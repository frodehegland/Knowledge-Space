//
//  AuthorMapDocument.swift
//  Knowledge Space
//
//  The bridge between the Map engine and Knowledge Space documents
//  (`.liquid.json`): `concepts` become nodes (with their tags carried in a
//  synthesized glossary), `references` become citation nodes, `connections`
//  become threads, and the document's primary spatial layout carries the
//  x/y/z positions. Saving writes those fields back through LiquidDoc's
//  canonical serializer; the body, links, and everything else in the
//  document are left as they stand.
//

import Foundation

enum KnowledgeMapDocumentError: Error, CustomStringConvertible {
    case unreadable(URL)

    var description: String {
        switch self {
        case .unreadable(let url):
            return "'\(url.lastPathComponent)' could not be read"
        }
    }
}

enum KnowledgeMapDocument {

    struct Contents {
        var flowDocument: FlowDocument
        var glossary: Glossary?
        var title: String?
    }

    // MARK: - Load

    /// Loads the map from a `.liquid.json` document using a coordinated
    /// read, so synced documents download and don't conflict.
    static func load(from url: URL) throws -> Contents {
        guard let data = coordinatedRead(url) else {
            throw KnowledgeMapDocumentError.unreadable(url)
        }
        let doc = try LiquidDoc.decode(data: data, fileURL: url)
        return contents(of: doc)
    }

    /// Builds the map from a document's concept/citation pool.
    static func contents(of doc: LiquidDoc) -> Contents {
        let glossary = Glossary()
        var nodes: Set<FlowNode> = []

        for concept in doc.concepts {
            glossary.add(GlossaryEntry(
                identifier: concept.id,
                phrase: concept.name,
                entry: concept.description,
                urls: concept.urls.map { GlossaryURL(url: $0) },
                citationIdentifiers: concept.citationIdentifiers,
                tagIdentifier: concept.tag ?? ""
            ))
            nodes.insert(FlowNode(identifier: concept.id,
                                  title: concept.name,
                                  definition: concept.description.isEmpty ? nil : concept.description,
                                  type: .text))
        }

        for reference in doc.references {
            let node = FlowNode(identifier: reference.id,
                                title: citationTitle(in: reference.bibtex) ?? reference.id,
                                type: .citation)
            node.citationIdentifier = reference.id
            nodes.insert(node)
        }

        // The lowest-index layout is the document's primary arrangement —
        // the one the volume edits; the rest ride along as custom layouts.
        let sortedLayouts = doc.layouts.sorted { $0.index < $1.index }

        var layout = CanvasViewLayout()
        if let primary = sortedLayouts.first {
            for position in primary.positions {
                layout.set(position: NodePosition(x: position.x, y: position.y, z: position.z),
                           for: position.id)
            }
        }
        seedMissingPositions(&layout, nodes: nodes)

        let customLayouts: [CustomLayout] = sortedLayouts.dropFirst().map { extra in
            var canvasLayout = CanvasViewLayout()
            for position in extra.positions {
                canvasLayout.set(position: NodePosition(x: position.x, y: position.y, z: position.z),
                                 for: position.id)
            }
            return CustomLayout(id: extra.sourceID ?? "layout-\(extra.index)",
                                name: extra.name,
                                layout: canvasLayout)
        }

        let connections = Set(doc.mapConnections.map {
            FlowConnection(identifier: "\($0.from)->\($0.to)",
                           endingNodeIdentifier: $0.to,
                           startNodeIdentifier: $0.from)
        })

        let flowDocument = FlowDocument(nodes: nodes,
                                        connections: FlowDocument.sanitizedConnections(connections),
                                        layout: layout,
                                        customLayouts: customLayouts)
        return Contents(flowDocument: flowDocument, glossary: glossary, title: doc.title)
    }

    // MARK: - Folder map

    /// Builds the map of a community folder as knowledge: every document a
    /// node whose **title is the term and whole body text the definition**
    /// (Knowledge Space's reading of a document — Author keeps its own),
    /// tagged by `documentType`, with `links` between the folder's
    /// documents as the connections. A document's `references` (BibTeX)
    /// simply ride along unrendered for now. Arrangements of the folder
    /// are the reader's own, never written into the documents; unplaced
    /// nodes start on the seeded grid.
    static func folderContents(documents: [LiquidDoc]) -> Contents {
        let glossary = Glossary()
        var nodes: Set<FlowNode> = []
        var seenIDs: Set<String> = []

        for doc in documents {
            guard seenIDs.insert(doc.id).inserted else { continue }
            let definition = (doc.body ?? [])
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            glossary.add(GlossaryEntry(
                identifier: doc.id,
                phrase: doc.title,
                entry: definition,
                urls: [],
                citationIdentifiers: [],
                tagIdentifier: doc.documentType ?? ""
            ))
            nodes.insert(FlowNode(identifier: doc.id,
                                  title: doc.title,
                                  definition: definition.isEmpty ? nil : definition,
                                  type: .text))
        }

        var connections: Set<FlowConnection> = []
        for doc in documents {
            for link in doc.links where seenIDs.contains(link.to) && link.to != doc.id {
                connections.insert(FlowConnection(identifier: "\(doc.id)->\(link.to)",
                                                  endingNodeIdentifier: link.to,
                                                  startNodeIdentifier: doc.id))
            }
        }

        var layout = CanvasViewLayout()
        seedMissingPositions(&layout, nodes: nodes)

        let flowDocument = FlowDocument(nodes: nodes,
                                        connections: FlowDocument.sanitizedConnections(connections),
                                        layout: layout,
                                        customLayouts: [])
        return Contents(flowDocument: flowDocument, glossary: glossary, title: nil)
    }

    // MARK: - Save

    /// Writes the map back into the document on disk, touching only
    /// `concepts`, `connections`, and the primary layout's positions.
    static func save(_ contents: Contents, to url: URL) throws {
        guard let data = coordinatedRead(url) else {
            throw KnowledgeMapDocumentError.unreadable(url)
        }
        var doc = try LiquidDoc.decode(data: data, fileURL: url)
        apply(contents, to: &doc)
        try coordinatedWrite(try doc.jsonData(), to: url)
    }

    static func apply(_ contents: Contents, to doc: inout LiquidDoc) {
        let flow = contents.flowDocument
        let referenceIDs = Set(doc.references.map(\.id))

        // Nodes backed by a reference stay represented by `references`;
        // every other node is a concept. (A citation node made on the map
        // without a BibTeX record becomes a concept, keeping name and tag.)
        doc.concepts = flow.nodes
            .filter { !referenceIDs.contains($0.identifier) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { node in
                let entry = node.glossaryEntry
                    ?? contents.glossary?.entryWith(identifier: node.identifier)
                let tag = entry?.tagIdentifier
                return LiquidDoc.Concept(
                    id: node.identifier,
                    name: node.name,
                    description: entry?.description ?? node.definition ?? "",
                    tag: (tag?.isEmpty ?? true) ? nil : tag,
                    citationIdentifiers: entry?.citationIdentifiers ?? [],
                    urls: (entry?.urls ?? []).map(\.url))
            }

        doc.mapConnections = flow.connections
            .map { LiquidDoc.MapConnection(from: $0.startNodeIdentifier, to: $0.endingNodeIdentifier) }
            .sorted { ($0.from, $0.to) < ($1.from, $1.to) }

        let nodeIDs = Set(flow.nodes.map(\.identifier))
        let positions = flow.layout.nodePositions
            .filter { nodeIDs.contains($0.key) }
            .map { LiquidDoc.Layout.Position(id: $0.key, x: $0.value.x, y: $0.value.y, z: $0.value.z) }
            .sorted { $0.id < $1.id }

        var layouts = doc.layouts.sorted { $0.index < $1.index }
        if layouts.isEmpty {
            layouts = [LiquidDoc.Layout(index: 1, name: "Map", positions: positions)]
        } else {
            layouts[0].positions = positions
        }
        doc.layouts = layouts
    }

    // MARK: - Helpers

    /// Positions for nodes the document doesn't place: a centered grid, so
    /// a document with concepts but no layout still opens as a readable map.
    private static func seedMissingPositions(_ layout: inout CanvasViewLayout, nodes: Set<FlowNode>) {
        let missing = nodes
            .filter { layout.nodePositions[$0.identifier] == nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !missing.isEmpty else { return }

        let columns = max(Int(Double(missing.count).squareRoot().rounded(.up)), 1)
        let rows = (missing.count + columns - 1) / columns
        for (index, node) in missing.enumerated() {
            let column = index % columns
            let row = index / columns
            layout.set(position: NodePosition(
                x: (Double(column) - Double(columns - 1) / 2) * 260,
                y: (Double(row) - Double(rows - 1) / 2) * 150,
                z: 0
            ), for: node.identifier)
        }
    }

    /// The title field of a BibTeX record, for the citation card's face.
    /// (`\b` keeps `booktitle` from matching.)
    private static func citationTitle(in bibtex: String) -> String? {
        let pattern = "\\btitle\\s*=\\s*[{\"]\\s*([^{}\"]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: bibtex, range: NSRange(bibtex.startIndex..., in: bibtex)),
              let range = Range(match.range(at: 1), in: bibtex) else { return nil }
        let title = bibtex[range].trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    // MARK: - Coordinated file access

    private static func coordinatedRead(_ url: URL) -> Data? {
        var data: Data?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { actualURL in
            data = try? Data(contentsOf: actualURL)
        }
        return data
    }

    private static func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { actualURL in
            do {
                try data.write(to: actualURL, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }
}
