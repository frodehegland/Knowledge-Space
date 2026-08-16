import Foundation

// Ported verbatim from Augmented Library's OrigamiEPUBExport.swift —
// access levels dropped, PDFIdentity.hash inlined as
// OrigamiReading.stableHash; a fix here should be carried back.
//
// Extracting a section as a document of its own, and writing it as an
// Origami-profile EPUB. The excerpt keeps the original's paragraph ids
// and declares its source (`excerptOf`), so a citation made from it
// addresses the original document and section — and a reader holding
// the original can open it at the right place. When the heading
// credits its own writer (Author's cmd-click attribution), that person
// is the excerpt's author; the original document's credit rides in
// `excerptOf`.

extension OrigamiReading {

    /// A section carved out as a document of its own: the heading and
    /// everything under it, to the next heading of the same or coarser
    /// rank. Paragraph ids are unchanged; endnotes the section cites
    /// ride along under their Notes heading; the reference, asset,
    /// table, and glossary pools are trimmed to what the section uses.
    static func excerpt(of doc: LiquidDoc, headingID: String) -> LiquidDoc? {
        guard let body = doc.body,
              let start = body.firstIndex(where: { $0.id == headingID }),
              let rank = body[start].heading else { return nil }

        var slice = [body[start]]
        var index = start + 1
        while index < body.count {
            if let level = body[index].heading, level <= rank { break }
            slice.append(body[index])
            index += 1
        }

        // Endnotes the slice references, appended under Notes with
        // their original ids.
        let noteIDs = tokenValues(pattern: #"\[note:([^\]]+)\]"#,
                                  in: slice.map(\.text).joined(separator: "\n"))
        let noteParagraphs = noteIDs.compactMap { id in
            slice.contains { $0.id == id } ? nil : body.first { $0.id == id }
        }
        var excerptBody = slice
        if !noteParagraphs.isEmpty {
            excerptBody.append(LiquidDoc.Paragraph(id: "notes", heading: 1, text: "Notes"))
            excerptBody.append(contentsOf: noteParagraphs)
        }

        // The pools, trimmed to the section.
        let citeKeys = Set(tokenValues(pattern: #"\[cite:([^\]]+)\]"#,
                                       in: slice.map(\.text).joined(separator: "\n")))
        let references = doc.references.filter { citeKeys.contains($0.id) }
        let assetIDs = Set(slice.compactMap { LiquidDoc.imageReference(in: $0.text)?.id })
        let assets = doc.assets.filter { assetIDs.contains($0.id) }
        let tableIDs = Set(slice.compactMap(\.tableID))
        let tables = doc.tables.filter { tableIDs.contains($0.identifier) }
        var conceptIDs: Set<String> = []
        var conceptList: [LiquidDoc.Concept] = []
        for paragraph in slice {
            for concept in concepts(in: paragraph, of: doc)
            where conceptIDs.insert(concept.id).inserted {
                conceptList.append(concept)
            }
        }

        // The excerpt's identity: the section's own writer when the
        // heading credits one, the original's author otherwise; a
        // deterministic id, so re-extracting is the same document.
        let heading = body[start]
        let author = heading.contributingAuthors ?? doc.author
        let excerptID = "excerpt-"
            + String(OrigamiReading.stableHash(of: doc.id + "#" + headingID).prefix(16))
        var excerpt = LiquidDoc(
            format: LiquidDoc.knownFormat,
            id: excerptID,
            title: "\(doc.title) — \(heading.text)",
            author: author,
            created: Date(),
            body: excerptBody,
            links: [],
            wraps: nil,
            date: doc.date,
            documentType: LiquidDoc.DocumentType.extract.rawValue,
            concepts: conceptList,
            references: references,
            tables: tables,
            assets: assets,
            fileURL: doc.fileURL)
        excerpt.excerptOf = LiquidDoc.ExcerptOf(
            id: doc.id,
            title: doc.title,
            author: doc.author,
            date: doc.date?.isoString,
            headingID: headingID,
            headingText: heading.text)
        return excerpt
    }

    /// What Copy as Citation puts on the clipboard for Author: the
    /// quoted words plain, and a full BibTeX entry for the cited work.
    /// From an excerpt the entry is chapter-style — the section's
    /// writer as author, the section as title, the original document
    /// as booktitle under its own author — and either way `vm-id`
    /// carries the original document's address with the paragraph
    /// fragment, so a citation exported onward (Author's EPUB) still
    /// opens the original document at the right place.
    static func authorCitationPayload(for paragraph: LiquidDoc.Paragraph,
                                             in doc: LiquidDoc)
        -> (content: String, bibtex: String) {
        let sourceID = doc.excerptOf?.id ?? doc.id
        let address = sourceID + "#" + paragraph.id
        let quote = plainQuote(paragraph.text, in: doc)

        var type = "misc"
        var fields: [(String, String)] = []
        if let excerpt = doc.excerptOf {
            let sectionAuthor = doc.author
            if !sectionAuthor.isEmpty,
               sectionAuthor.caseInsensitiveCompare(excerpt.author) != .orderedSame {
                type = "incollection"
                fields.append(("author", sectionAuthor))
                fields.append(("title", excerpt.headingText))
                fields.append(("booktitle", excerpt.title))
                if !excerpt.author.isEmpty { fields.append(("editor", excerpt.author)) }
            } else {
                if !excerpt.author.isEmpty { fields.append(("author", excerpt.author)) }
                fields.append(("title", excerpt.title))
            }
            if let year = excerpt.date?.prefix(4), year.count == 4 {
                fields.append(("year", String(year)))
            }
        } else {
            if !doc.author.isEmpty { fields.append(("author", doc.author)) }
            fields.append(("title", doc.title))
            if let year = doc.date?.isoString.prefix(4), year.count == 4 {
                fields.append(("year", String(year)))
            }
        }
        if !quote.isEmpty { fields.append(("quote", quote)) }
        fields.append(("vm-id", address))

        let key = "al" + String(OrigamiReading.stableHash(of: address).prefix(10))
        var bibtex = "@\(type){\(key),\n"
        for (name, value) in fields {
            bibtex += " \(name) = {\(bibValue(value))},\n"
        }
        bibtex += "}"
        return (content: quote, bibtex: bibtex)
    }

    /// A paragraph's words with the reading conventions resolved away —
    /// citations in author–date words, note daggers and mark/emphasis
    /// syntax gone — fit for a quotation field.
    static func plainQuote(_ text: String, in doc: LiquidDoc) -> String {
        var out = citationsResolved(text, in: doc, style: .authorDate)
        if let regex = try? NSRegularExpression(pattern: #"\[note:[^\]]+\]"#) {
            let ns = out as NSString
            out = regex.stringByReplacingMatches(
                in: out, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        }
        for marker in ["==", "**", "*", "`"] {
            out = out.replacingOccurrences(of: marker, with: "")
        }
        return out.replacingOccurrences(of: #"\s+"#, with: " ",
                                        options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A value safe inside one BibTeX brace pair — braces and newlines
    /// would break the receiving parsers.
    private static func bibValue(_ value: String) -> String {
        value.replacingOccurrences(of: "{", with: "(")
            .replacingOccurrences(of: "}", with: ")")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokenValues(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var values: [String] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let value = ns.substring(with: match.range(at: 1))
            if !values.contains(value) { values.append(value) }
        }
        return values
    }
}

/// Writing an Origami-profile EPUB — the mirror of the importer. The
/// body's conventions fold back to the export's XHTML forms, the
/// metadata (excerpt provenance, glossary, references, endnotes) rides
/// in origami.json, and images travel as files. The package is a
/// stored (uncompressed) ZIP with true CRCs, valid for any reader.
nonisolated enum OrigamiEPUBExporter {

    /// Writes the document as an EPUB at the URL.
    static func write(_ doc: LiquidDoc, to url: URL,
                             generator: String = "Augmented Library") throws {
        var zip = ZipWriter()
        zip.add(path: "mimetype", data: Data("application/epub+zip".utf8))
        zip.add(path: "META-INF/container.xml", data: Data(containerXML.utf8))

        let (xhtml, imageFiles) = contentXHTML(for: doc)
        zip.add(path: "OEBPS/content.opf",
                data: Data(packageOPF(for: doc, imageFiles: imageFiles).utf8))
        zip.add(path: "OEBPS/nav.xhtml", data: Data(navXHTML(for: doc).utf8))
        zip.add(path: "OEBPS/content.xhtml", data: Data(xhtml.utf8))
        zip.add(path: "OEBPS/origami.json",
                data: try origamiJSON(for: doc, generator: generator))
        for file in imageFiles {
            zip.add(path: "OEBPS/images/\(file.name)", data: file.data)
        }
        try zip.finish().write(to: url, options: .atomic)
    }

    // MARK: - The content document

    /// The note paragraphs (the Notes section) ride in origami.json,
    /// not the body — the importer puts them back.
    static func splitNotes(from doc: LiquidDoc)
        -> (body: [LiquidDoc.Paragraph], endnotes: [LiquidDoc.Paragraph]) {
        let body = doc.body ?? []
        guard let notesIndex = body.firstIndex(where: {
            $0.id == "notes" && $0.heading != nil
        }) else { return (body, []) }
        return (Array(body[..<notesIndex]), Array(body[(notesIndex + 1)...]))
    }

    private static func contentXHTML(for doc: LiquidDoc)
        -> (xhtml: String, images: [(name: String, mediaType: String, data: Data)]) {
        var html = ""
        var images: [(name: String, mediaType: String, data: Data)] = []
        let (body, _) = splitNotes(from: doc)

        var openStretch: String?
        func closeStretch() {
            if openStretch != nil {
                html += "</aside>\n"
                openStretch = nil
            }
        }

        for paragraph in body {
            if paragraph.stretchID != openStretch { closeStretch() }
            if let stretchID = paragraph.stretchID, openStretch == nil {
                html += "<aside class=\"ot-stretchtext-content\" id=\"\(escape(stretchID))\" hidden=\"hidden\">\n"
                openStretch = stretchID
            }

            if let level = paragraph.heading {
                closeStretch()
                let tag = "h\(min(level, 3) + 1)"
                let contributing = paragraph.contributingAuthors.map {
                    " data-contributing-authors=\"\(escape($0))\""
                } ?? ""
                html += "<\(tag) id=\"\(escape(paragraph.id))\"\(contributing)>"
                    + inlineHTML(paragraph.text, doc: doc) + "</\(tag)>\n"
            } else if let image = LiquidDoc.imageReference(in: paragraph.text),
                      let asset = doc.assets.first(where: { $0.id == image.id }),
                      let data = asset.data {
                let name = asset.filename.isEmpty ? "\(asset.id).png" : asset.filename
                if !images.contains(where: { $0.name == name }) {
                    images.append((name, asset.mediaType, data))
                }
                let alt = escape(image.alt)
                html += "<figure id=\"\(escape(paragraph.id))\">"
                    + "<img src=\"images/\(escape(name))\" alt=\"\(alt)\"/></figure>\n"
            } else if let tableID = paragraph.tableID {
                html += tableHTML(paragraph: paragraph, tableID: tableID, doc: doc)
            } else if paragraph.text == "---" {
                html += "<hr/>\n"
            } else {
                html += "<p id=\"\(escape(paragraph.id))\">"
                    + inlineHTML(paragraph.text, doc: doc) + "</p>\n"
            }
        }
        closeStretch()

        let xhtml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>\(escape(doc.title))</title></head>
        <body>
        <section>
        \(html)</section>
        </body>
        </html>
        """
        return (xhtml, images)
    }

    /// One paragraph's text folded to the export's inline forms:
    /// escapes first, then citations and note daggers as their anchors,
    /// marks, strong/em, code, and plain links.
    static func inlineHTML(_ text: String, doc: LiquidDoc) -> String {
        var out = escape(text)
        // Citations: the anchor carries the key; the visible label is
        // the author–date reading, for readers without the metadata.
        out = replacing(out, pattern: #"\[cite:([^\]]+)\]"#) { groups in
            let key = groups[0]
            let label = OrigamiReading.citationsResolved(
                "[cite:\(key)]", in: doc, style: .authorDate)
            return "<a epub:type=\"biblioref\" role=\"doc-biblioref\" "
                + "data-citation-key=\"\(key)\" "
                + "href=\"backmatter.xhtml#bib-\(key)\">\(escape(label))</a>"
        }
        // Endnote daggers — the fragment is the note's id exactly,
        // the same id origami.json carries, so the token round-trips.
        out = replacing(out, pattern: #"\[note:([^\]]+)\]"#) { groups in
            "<a epub:type=\"noteref\" role=\"doc-noteref\" "
                + "href=\"backmatter.xhtml#\(groups[0])\">&#8224;</a>"
        }
        // Author's Mark, bold, italic, code — non-greedy pairs.
        out = replacing(out, pattern: #"==([^=]+)=="#) { "<mark>\($0[0])</mark>" }
        out = replacing(out, pattern: #"\*\*([^*]+)\*\*"#) { "<strong>\($0[0])</strong>" }
        out = replacing(out, pattern: #"\*([^*]+)\*"#) { "<em>\($0[0])</em>" }
        out = replacing(out, pattern: #"`([^`]+)`"#) { "<code>\($0[0])</code>" }
        // Markdown links (the cite/note tokens are already consumed).
        out = replacing(out, pattern: #"\[([^\]]+)\]\((https?://[^)\s]+)\)"#) {
            "<a href=\"\($0[1])\">\($0[0])</a>"
        }
        return out
    }

    private static func tableHTML(paragraph: LiquidDoc.Paragraph, tableID: String,
                                  doc: LiquidDoc) -> String {
        guard let table = doc.tables.first(where: { $0.identifier == tableID }) else {
            return "<p id=\"\(escape(paragraph.id))\">"
                + inlineHTML(paragraph.text, doc: doc) + "</p>\n"
        }
        var html = "<table id=\"\(escape(paragraph.id))\" data-table-id=\"\(escape(tableID))\">\n"
        for row in table.cells {
            html += "<tr>"
            for cell in row {
                html += "<td>\(escape(cell.value))</td>"
            }
            html += "</tr>\n"
        }
        html += "</table>\n"
        return html
    }

    // MARK: - The metadata

    private static func origamiJSON(for doc: LiquidDoc,
                                    generator: String) throws -> Data {
        var root: [String: Any] = [:]
        var document: [String: Any] = [
            "title": doc.title,
            "authors": [["name": doc.author]],
            "origami-id": doc.id,
            "id": "urn:al:\(doc.id)",
        ]
        if let date = doc.date {
            document["date"] = date.isoString
        }
        root["document"] = document
        root["origami"] = ["format": "origami-text", "generator": generator]

        if let excerpt = doc.excerptOf {
            var node: [String: Any] = [
                "id": excerpt.id,
                "title": excerpt.title,
                "author": excerpt.author,
                "headingID": excerpt.headingID,
                "headingText": excerpt.headingText,
            ]
            if let date = excerpt.date { node["date"] = date }
            root["excerptOf"] = node
        }
        if !doc.references.isEmpty {
            root["references"] = Dictionary(uniqueKeysWithValues:
                doc.references.map { ($0.id, ["bibtex": $0.bibtex]) })
        }
        if !doc.concepts.isEmpty {
            root["glossary"] = Dictionary(uniqueKeysWithValues:
                doc.concepts.map { concept in
                    (concept.id, ["phrase": concept.name,
                                  "entry": concept.description,
                                  "tags": concept.tag.map { [$0] } ?? [],
                                  "citations": concept.citationIdentifiers,
                                  "urls": concept.urls] as [String: Any])
                })
        }
        let (_, endnotes) = splitNotes(from: doc)
        if !endnotes.isEmpty {
            root["endnotes"] = endnotes.map { ["id": $0.id, "text": $0.text] }
        }
        return try JSONSerialization.data(withJSONObject: root,
                                          options: [.prettyPrinted, .sortedKeys])
    }

    private static func packageOPF(for doc: LiquidDoc,
                                   imageFiles: [(name: String, mediaType: String, data: Data)])
        -> String {
        var manifest = """
          <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
          <item id="content" href="content.xhtml" media-type="application/xhtml+xml"/>
          <item id="origami-metadata" href="origami.json" media-type="application/json"/>
        """
        for (index, file) in imageFiles.enumerated() {
            manifest += "\n  <item id=\"img\(index + 1)\" href=\"images/\(escape(file.name))\" media-type=\"\(escape(file.mediaType))\"/>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="pub-id">urn:al:\(escape(doc.id))</dc:identifier>
            <dc:title>\(escape(doc.title))</dc:title>
            <dc:creator>\(escape(doc.author))</dc:creator>
            \(doc.date.map { "<dc:date>\(escape($0.isoString))</dc:date>" } ?? "")
          </metadata>
          <manifest>
        \(manifest)
          </manifest>
          <spine><itemref idref="content"/></spine>
        </package>
        """
    }

    private static func navXHTML(for doc: LiquidDoc) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>\(escape(doc.title))</title></head>
        <body>
        <nav epub:type="toc"><ol><li><a href="content.xhtml">\(escape(doc.title))</a></li></ol></nav>
        </body>
        </html>
        """
    }

    private static let containerXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
    </container>
    """

    // MARK: - Small helpers

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func replacing(_ text: String, pattern: String,
                                  with builder: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var out = text as NSString
        for match in regex.matches(in: text,
                                   range: NSRange(location: 0, length: out.length)).reversed() {
            var groups: [String] = []
            for group in 1..<match.numberOfRanges {
                groups.append(out.substring(with: match.range(at: group)))
            }
            out = out.replacingCharacters(in: match.range,
                                          with: builder(groups)) as NSString
        }
        return out as String
    }
}

/// A minimal stored (uncompressed) ZIP writer with true CRC-32s —
/// enough for a valid EPUB, matched to the importer's reader.
nonisolated struct ZipWriter {
    private struct Entry {
        let path: String
        let data: Data
        let crc: UInt32
        let offset: Int
    }

    private var out = Data()
    private var entries: [Entry] = []

    mutating func add(path: String, data: Data) {
        let crc = ZipWriter.crc32(data)
        let offset = out.count
        let name = Data(path.utf8)
        out.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])   // local header
        appendUInt16(20)                                    // version
        appendUInt16(0)                                     // flags
        appendUInt16(0)                                     // stored
        appendUInt16(0); appendUInt16(0)                    // time, date
        appendUInt32(crc)
        appendUInt32(UInt32(data.count))                    // compressed
        appendUInt32(UInt32(data.count))                    // uncompressed
        appendUInt16(UInt16(name.count))
        appendUInt16(0)                                     // extra
        out.append(name)
        out.append(data)
        entries.append(Entry(path: path, data: data, crc: crc, offset: offset))
    }

    mutating func finish() -> Data {
        let directoryStart = out.count
        for entry in entries {
            let name = Data(entry.path.utf8)
            out.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])   // central header
            appendUInt16(20); appendUInt16(20)
            appendUInt16(0); appendUInt16(0)
            appendUInt16(0); appendUInt16(0)
            appendUInt32(entry.crc)
            appendUInt32(UInt32(entry.data.count))
            appendUInt32(UInt32(entry.data.count))
            appendUInt16(UInt16(name.count))
            appendUInt16(0); appendUInt16(0)                   // extra, comment
            appendUInt16(0); appendUInt16(0)                   // disk, internal
            appendUInt32(0)                                    // external attrs
            appendUInt32(UInt32(entry.offset))
            out.append(name)
        }
        let directorySize = out.count - directoryStart
        out.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])       // end record
        appendUInt16(0); appendUInt16(0)
        appendUInt16(UInt16(entries.count))
        appendUInt16(UInt16(entries.count))
        appendUInt32(UInt32(directorySize))
        appendUInt32(UInt32(directoryStart))
        appendUInt16(0)                                        // comment
        return out
    }

    private mutating func appendUInt16(_ value: UInt16) {
        out.append(UInt8(value & 0xFF))
        out.append(UInt8(value >> 8))
    }

    private mutating func appendUInt32(_ value: UInt32) {
        out.append(UInt8(value & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
        out.append(UInt8((value >> 16) & 0xFF))
        out.append(UInt8((value >> 24) & 0xFF))
    }

    /// Standard CRC-32 (the ZIP polynomial).
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (0xEDB88320 & (0 &- (crc & 1)))
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}
