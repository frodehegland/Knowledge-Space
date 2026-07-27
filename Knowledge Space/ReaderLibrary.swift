import Foundation
import PDFKit
import FoundationModels
#if os(macOS)
import AppKit
#endif

// The Reader Library: the folder where Reader keeps its PDFs, granted
// once and remembered. Knowledge Space walks it for PDFs carrying a
// Visual-Meta appendix; every find becomes a source document on the
// shelf — the PDF itself never moves — naming the PDF and its folder so
// this Mac can follow the source back to the work and open it.

// MARK: - Visual-Meta in PDFs

/// Reads the Visual-Meta self-citation out of a PDF, end-anchored as
/// the format instructs: the last `@{visual-meta-end}` is looked for
/// first — no end tag in the closing pages, no appendix, done — then
/// the nearest `@{visual-meta-start}` before it, and the self-citation
/// between them.
nonisolated enum PDFVisualMeta {

    static let endMarker = "@{visual-meta-end}"

    /// Everything a PDF's Visual-Meta gives the library: the
    /// self-citation (whose `abstract` field is the canonical summary
    /// where present), and Reader's margin — every delimited section
    /// whose name speaks of notes, annotations, highlights, or
    /// comments, each entry becoming an annotation document.
    struct Harvest: Sendable {
        let record: BibTeXRecord
        let annotations: [Annotation]

        struct Annotation: Sendable {
            let text: String
            let locator: String?
        }

        var abstract: String? {
            let text = record.fields["abstract"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        }
    }

    /// The PDF's Visual-Meta harvest, or nil when the PDF carries
    /// none. Pages are read from the end forward — the appendix
    /// lives at the back — and the look gives up quietly when the end
    /// tag has not shown within the closing pages.
    static func harvest(inPDFAt url: URL) -> Harvest? {
        guard let pdf = PDFDocument(url: url) else { return nil }
        var text = ""
        var pageIndex = pdf.pageCount - 1
        var pagesRead = 0
        var sawEnd = false
        while pageIndex >= 0, pagesRead < 24 {
            guard let page = pdf.page(at: pageIndex) else { break }
            text = (page.string ?? "") + text
            pagesRead += 1
            pageIndex -= 1
            if !sawEnd {
                if text.contains(endMarker) {
                    sawEnd = true
                } else if pagesRead >= 4 {
                    // The end tag first: absent from the closing pages,
                    // the PDF carries no Visual-Meta.
                    return nil
                }
            }
            if sawEnd, text.contains(VisualMeta.startMarker) { break }
        }
        guard let end = text.range(of: endMarker, options: .backwards),
              let start = text.range(of: VisualMeta.startMarker, options: .backwards,
                                     range: text.startIndex..<end.lowerBound)
        else { return nil }
        // PDF text extraction can inject object-replacement characters;
        // they go before the block is read.
        let block = String(text[start.upperBound..<end.lowerBound])
            .replacingOccurrences(of: "\u{FFFC}", with: "")
        guard let citationStart = block.range(of: "@{visual-meta-bibtex-self-citation-start}"),
              let citationEnd = block.range(of: "@{visual-meta-bibtex-self-citation-end}",
                                            range: citationStart.upperBound..<block.endIndex)
        else { return nil }
        let citation = String(block[citationStart.upperBound..<citationEnd.lowerBound])
        guard let record = BibTeXRecord.records(in: citation).first else { return nil }
        return Harvest(record: record, annotations: annotations(in: block))
    }

    /// Reader's margin, read generically per the Visual-Meta approach
    /// ("new wrappers may be added, each delimited the same way"):
    /// every `@{<name>-start}`…`@{<name>-end}` section whose name
    /// speaks of notes, annotations, highlights, or comments. Entries
    /// parse where they are BibTeX-shaped (text, quote, or comment
    /// fields; page or locator for the place); a section that is plain
    /// prose arrives whole.
    private static func annotations(in block: String) -> [Harvest.Annotation] {
        var found: [Harvest.Annotation] = []
        for section in sections(in: block) {
            let name = section.name.lowercased()
            guard name.contains("note") || name.contains("annotation")
                    || name.contains("highlight") || name.contains("comment")
            else { continue }
            let entries = BibTeXRecord.records(in: section.content)
            if entries.isEmpty {
                let text = section.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    found.append(Harvest.Annotation(text: text, locator: nil))
                }
            } else {
                for entry in entries {
                    let text = entry.fields["text"] ?? entry.fields["quote"]
                        ?? entry.fields["comment"] ?? entry.fields["note"]
                        ?? entry.fields["content"] ?? ""
                    guard !text.isEmpty else { continue }
                    let locator = entry.fields["locator"]
                        ?? entry.fields["page"].map { "p. \($0)" }
                    found.append(Harvest.Annotation(text: text, locator: locator))
                }
            }
        }
        return found
    }

    /// Every delimited section of the appendix, by name.
    private static func sections(in block: String) -> [(name: String, content: String)] {
        var result: [(String, String)] = []
        var search = block.startIndex
        while let start = block.range(of: "@{", range: search..<block.endIndex) {
            guard let close = block.range(of: "}", range: start.upperBound..<block.endIndex)
            else { break }
            let tag = String(block[start.upperBound..<close.lowerBound])
            search = close.upperBound
            guard tag.hasSuffix("-start") else { continue }
            let name = String(tag.dropLast("-start".count))
            guard let end = block.range(of: "@{\(name)-end}",
                                        range: close.upperBound..<block.endIndex)
            else { continue }
            result.append((name, String(block[close.upperBound..<end.lowerBound])))
            search = end.upperBound
        }
        return result
    }
}

// MARK: - The Reader Library on AppState

extension AppState {

    private static let readerBookmarkKey = "readerLibraryBookmark"

    /// Grants the Reader Library: remembered like the community folder,
    /// and scanned at once.
    func chooseReaderLibrary(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        #if os(macOS)
        let data = try? url.bookmarkData(options: .withSecurityScope,
                                         includingResourceValuesForKeys: nil,
                                         relativeTo: nil)
        #else
        let data = try? url.bookmarkData()
        #endif
        UserDefaults.standard.set(data, forKey: Self.readerBookmarkKey)
        readerLibraryURL = url
        scanReaderLibrary()
    }

    /// Re-opens the granted folder at launch.
    func restoreReaderLibrary() {
        guard let data = UserDefaults.standard.data(forKey: Self.readerBookmarkKey) else { return }
        var isStale = false
        #if os(macOS)
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: .withSecurityScope,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &isStale) else { return }
        #else
        guard let url = try? URL(resolvingBookmarkData: data,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &isStale) else { return }
        #endif
        _ = url.startAccessingSecurityScopedResource()
        readerLibraryURL = url
    }

    /// The quiet launch scan, once the library index has been read —
    /// finds must be minted against a known shelf.
    func readerLibraryUpkeep() {
        guard !readerScanDone, readerLibraryURL != nil,
              index.folderURL != nil, !index.isScanning else { return }
        readerScanDone = true
        scanReaderLibrary(quiet: true)
    }

    /// Walks the Reader Library for PDFs carrying Visual-Meta; every
    /// find not already shelved becomes a source document pointing at
    /// its PDF by name and folder. The PDFs are read, never touched.
    func scanReaderLibrary(quiet: Bool = false) {
        guard let reader = readerLibraryURL else {
            if !quiet { showNote("Choose the Reader Library folder first — Settings ▸ Library.") }
            return
        }
        guard index.folderURL != nil else {
            if !quiet { showNote("Choose a community folder first — sources live there.") }
            return
        }
        // One scan at a time: the launch scan and a Scan Now racing
        // each other minted the same works twice.
        guard !readerScanRunning else { return }
        readerScanRunning = true
        tidyDuplicateSources()
        let knownIDs = Set(index.allByID.keys)
        Task.detached(priority: .utility) {
            var finds: [(name: String, folder: String, harvest: PDFVisualMeta.Harvest, derivedID: String?)] = []
            let enumerator = FileManager.default.enumerator(
                at: reader, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension.lowercased() == "pdf" else { continue }
                // A Visual-Meta ecosystem file name names its address;
                // already shelved means already done, no parse needed.
                let derived = LiquidDoc.identityKeyID(inFileName: url.lastPathComponent)
                if let derived, knownIDs.contains(derived) { continue }
                guard let harvest = PDFVisualMeta.harvest(inPDFAt: url) else { continue }
                finds.append((url.lastPathComponent,
                              url.deletingLastPathComponent().path,
                              harvest,
                              derived))
            }
            let results = finds
            await MainActor.run {
                self.adoptReaderFinds(results, quiet: quiet)
            }
        }
    }

    private func adoptReaderFinds(
        _ finds: [(name: String, folder: String, harvest: PDFVisualMeta.Harvest, derivedID: String?)],
        quiet: Bool
    ) {
        defer { readerScanRunning = false }
        guard let folderURL = index.folderURL else { return }
        var added = 0
        var annotationsAdded = 0
        // Keys minted in this batch: the same work met twice in one
        // walk (two copies of a PDF) shelves once.
        var mintedKeys: Set<String> = []
        for find in finds {
            let record = find.harvest.record
            guard mintedKeys.insert(record.key.lowercased()).inserted else { continue }
            // The deterministic address: the file name's identity key,
            // else derived from the self-citation's author and vm-id
            // (§3 — anyone who knows both can derive it), else minted.
            var derived = find.derivedID
            if derived == nil, let stamp = record.fields["vm-id"],
               let created = LiquidDoc.parseISO8601(stamp),
               let author = record.individualAuthors.first {
                derived = LiquidAddress.makeID(author: author, created: created)
            }
            let docID = derived
                ?? LiquidAddress.makeID(author: authorName) { self.index.isIDTaken($0) }
            guard index.allByID[docID] == nil,
                  existingSource(forKey: record.key) == nil else { continue }
            var paragraphs = [
                LiquidDoc.Paragraph(id: "p1", heading: nil,
                                    text: record.citationSentence + " [\(docID)]"),
                LiquidDoc.Paragraph(id: "p2", heading: nil,
                                    text: "PDF: \(find.name) — kept in \(find.folder) on the importing Mac."),
            ]
            // The abstract is the work's canonical summary (§7): it
            // stands on the source's own page.
            if let abstract = find.harvest.abstract {
                paragraphs.append(LiquidDoc.Paragraph(id: "p3", heading: 2, text: "Abstract"))
                paragraphs.append(LiquidDoc.Paragraph(id: "p4", heading: nil, text: abstract))
            }
            var doc = LiquidDoc(
                format: LiquidDoc.knownFormat,
                id: docID,
                title: record.title.isEmpty ? find.name : record.title,
                author: authorName,
                created: .now,
                body: paragraphs,
                links: [],
                wraps: nil,
                fileURL: folderURL.appendingPathComponent(docID)
                    .appendingPathExtension(LiquidDoc.fileExtension))
            doc.documentType = LiquidDoc.DocumentType.source.rawValue
            doc.references = [LiquidDoc.Reference(id: record.key, bibtex: record.raw)]
            if !record.year.isEmpty {
                doc.date = LiquidDate(isoString: record.year)
            }
            if (try? doc.jsonData().write(to: doc.fileURL, options: .atomic)) != nil {
                added += 1
                // Reader's margin comes along: every note and highlight
                // the PDF's Visual-Meta carried becomes an annotation
                // document standing on the source.
                annotationsAdded += adoptAnnotations(find.harvest.annotations,
                                                     sourceID: docID,
                                                     sourceBibtex: record.raw,
                                                     in: folderURL)
            }
        }
        if added > 0 { index.rescan() }
        if !quiet || added > 0 {
            var parts: [String] = []
            if added > 0 { parts.append("\(added) source\(added == 1 ? "" : "s")") }
            if annotationsAdded > 0 {
                parts.append("\(annotationsAdded) annotation\(annotationsAdded == 1 ? "" : "s")")
            }
            showNote(parts.isEmpty
                ? "No new Visual-Meta PDFs in the Reader Library."
                : parts.joined(separator: " and ") + " joined the shelf from the Reader Library.")
        }
    }

    /// Reader's margin notes as annotation documents, each linked
    /// `annotates` to its source with the place it spoke of.
    private func adoptAnnotations(_ annotations: [PDFVisualMeta.Harvest.Annotation],
                                  sourceID: String, sourceBibtex: String,
                                  in folderURL: URL) -> Int {
        var added = 0
        for annotation in annotations {
            let created = Date.now
            let id = LiquidAddress.makeID(author: authorName, created: created) {
                self.index.isIDTaken($0)
            }
            let title = annotation.text.split(whereSeparator: \.isWhitespace)
                .prefix(4).joined(separator: " ")
            var doc = LiquidDoc(
                format: LiquidDoc.knownFormat,
                id: id,
                title: title.isEmpty ? "Untitled" : title,
                author: authorName,
                created: created,
                body: LiquidDoc.parseBody(from: annotation.text),
                links: [LiquidDoc.Link(to: sourceID, fragment: nil, rel: "annotates",
                                       locator: annotation.locator)],
                wraps: nil,
                fileURL: folderURL.appendingPathComponent(id)
                    .appendingPathExtension(LiquidDoc.fileExtension))
            doc.documentType = LiquidDoc.DocumentType.annotation.rawValue
            if (try? doc.jsonData().write(to: doc.fileURL, options: .atomic)) != nil {
                added += 1
            }
        }
        return added
    }

    /// Re-reads the Visual-Meta of every shelved source whose PDF this
    /// Mac can reach, refreshing what the first scans may have missed:
    /// the work's title and authors on the record, the citation
    /// sentence, the abstract, and Reader's margin notes. The user's
    /// own word stands — a source reshelved as a book keeps its kind,
    /// and annotations already present are not doubled.
    func reharvestSources() {
        guard readerLibraryURL != nil else {
            showNote("Choose the Reader Library folder first — Settings ▸ Library.")
            return
        }
        guard !readerScanRunning else { return }
        readerScanRunning = true
        let candidates = sourceEntries.map(\.doc)
            .compactMap { doc -> (id: String, pdf: URL)? in
                guard let url = sourcePDFURL(for: doc) else { return nil }
                return (doc.id, url)
            }
        readerRescanProgress = AppState.AnalysisProgress(done: 0, total: candidates.count)
        Task {
            var refreshed = 0
            var annotationsAdded = 0
            for (finished, candidate) in candidates.enumerated() {
                readerRescanProgress = AppState.AnalysisProgress(done: finished,
                                                                 total: candidates.count)
                // The PDF read is the slow part — off the main actor.
                let harvest = await Task.detached(priority: .utility) {
                    PDFVisualMeta.harvest(inPDFAt: candidate.pdf)
                }.value
                guard let harvest else { continue }
                let result = applyOneReharvest(docID: candidate.id, harvest: harvest)
                if result.refreshed { refreshed += 1 }
                annotationsAdded += result.annotations
                // The shelf shows each fresh title the moment its work
                // is read, not at the end of the walk.
                if result.refreshed || result.annotations > 0 {
                    index.rescan()
                }
            }
            readerScanRunning = false
            readerRescanProgress = nil
            var parts: [String] = []
            if refreshed > 0 { parts.append("\(refreshed) source\(refreshed == 1 ? "" : "s") refreshed") }
            if annotationsAdded > 0 {
                parts.append("\(annotationsAdded) annotation\(annotationsAdded == 1 ? "" : "s") added")
            }
            showNote(parts.isEmpty
                ? "The shelf already matches its PDFs."
                : parts.joined(separator: ", ") + ".")
        }
    }

    /// One source refreshed from its PDF's harvest; the caller rescans.
    private func applyOneReharvest(docID: String,
                                   harvest: PDFVisualMeta.Harvest) -> (refreshed: Bool, annotations: Int) {
        guard let folderURL = index.folderURL,
              let current = index.allByID[docID]?.doc,
              let data = try? Data(contentsOf: current.fileURL),
              var doc = try? LiquidDoc.decode(data: data, fileURL: current.fileURL)
        else { return (false, 0) }
        let item = (docID: docID, harvest: harvest)
        var annotationsAdded = 0
        let record = item.harvest.record
        var changed = false
            // The record refreshes; a kind the user assigned stays.
            var fresh = record.raw
            if let existing = doc.references.first,
               existing.bibtex.lowercased().hasPrefix("@book"),
               !fresh.lowercased().hasPrefix("@book"),
               let brace = fresh.firstIndex(of: "{") {
                fresh = "@book" + fresh[brace...]
            }
            if doc.references.first?.bibtex != fresh
                || doc.references.first?.id != record.key {
                doc.references = [LiquidDoc.Reference(id: record.key, bibtex: fresh)]
                changed = true
            }
            // The work's own title takes over from a file's name.
            if !record.title.isEmpty, doc.title != record.title {
                doc.title = record.title
                changed = true
            }
            var body = doc.body ?? []
            // The citation sentence at the top follows the record.
            let sentence = record.citationSentence + " [\(doc.id)]"
            if let first = body.first, !first.text.hasPrefix("PDF: "),
               first.text != sentence {
                body[0] = LiquidDoc.Paragraph(id: first.id, heading: first.heading,
                                              text: sentence)
                changed = true
            }
            // The abstract joins where the first scan had none.
            if let abstract = item.harvest.abstract,
               !body.contains(where: { $0.heading == 2 && $0.text == "Abstract" }) {
                func uniqueID(_ base: String) -> String {
                    var id = base
                    var counter = 1
                    while body.contains(where: { $0.id == id }) {
                        counter += 1
                        id = "\(base)\(counter)"
                    }
                    return id
                }
                let pdfLine = body.firstIndex { $0.text.hasPrefix("PDF: ") }
                let insertAt = min(body.count, (pdfLine ?? (body.isEmpty ? -1 : 0)) + 1)
                let heading = LiquidDoc.Paragraph(id: uniqueID("abs"), heading: 2,
                                                  text: "Abstract")
                body.insert(heading, at: insertAt)
                body.insert(LiquidDoc.Paragraph(id: uniqueID("abst"), heading: nil,
                                                text: abstract),
                            at: insertAt + 1)
                changed = true
            }
            var wrote = false
            if changed {
                doc.body = body
                if !record.year.isEmpty, doc.date == nil {
                    doc.date = LiquidDate(isoString: record.year)
                }
                wrote = (try? doc.jsonData().write(to: doc.fileURL, options: .atomic)) != nil
            }
            // Reader's margin, where none stands yet.
            let hasAnnotations = (index.backlinks[doc.id] ?? []).contains { ref in
                index.allByID[ref.fromID]?.doc.documentType
                    == LiquidDoc.DocumentType.annotation.rawValue
            }
            if !hasAnnotations, !item.harvest.annotations.isEmpty {
                annotationsAdded += adoptAnnotations(item.harvest.annotations,
                                                     sourceID: doc.id,
                                                     sourceBibtex: record.raw,
                                                     in: folderURL)
            }
        return (wrote, annotationsAdded)
    }

    /// Sources sharing one BibTeX key are one work shelved twice — the
    /// racing scans of an earlier build could mint them. The earliest
    /// record stays (preferring any with connections); the extras go
    /// to the Trash, recoverable there.
    func tidyDuplicateSources() {
        var byKey: [String: [LiquidDoc]] = [:]
        for entry in sourceEntries {
            guard let key = entry.doc.references.first?.id.lowercased(),
                  !key.isEmpty else { continue }
            byKey[key, default: []].append(entry.doc)
        }
        var removed = 0
        for (_, docs) in byKey where docs.count > 1 {
            let keeper = docs.min { a, b in
                let aLinks = index.backlinks[a.id]?.count ?? 0
                let bLinks = index.backlinks[b.id]?.count ?? 0
                if aLinks != bLinks { return aLinks > bLinks }
                return a.created < b.created
            }
            for doc in docs where doc.id != keeper?.id {
                // Only untouched records leave — a duplicate someone
                // has already quoted or cited stays put.
                guard (index.backlinks[doc.id] ?? []).isEmpty else { continue }
                if (try? FileManager.default.trashItem(at: doc.fileURL,
                                                       resultingItemURL: nil)) != nil {
                    removed += 1
                }
            }
        }
        if removed > 0 {
            index.rescan()
            showNote("\(removed) duplicate source record\(removed == 1 ? "" : "s") moved to the Trash.")
        }
    }

    /// Follows a source's "PDF:" line to the file and hands it to the
    /// Mac's PDF app — Reader, where Reader owns PDFs. The granted
    /// Reader Library resolves the name first, the recorded folder
    /// second (paths are the importing Mac's own).
    func openSourcePDF(named name: String, recordedFolder: String?) {
        var candidates: [URL] = []
        if let readerLibraryURL {
            candidates.append(readerLibraryURL.appendingPathComponent(name))
        }
        if let recordedFolder {
            candidates.append(URL(fileURLWithPath: recordedFolder)
                .appendingPathComponent(name))
        }
        guard let url = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            showNote("The PDF “\(name)” is not where this Mac knows to look — grant the Reader Library in Settings ▸ Library.")
            return
        }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }
}

// MARK: - Studying the works (on-device)

/// The on-device study of a source's PDF: a summary, keywords, the
/// names mentioned, and the concepts it leans on. Runs on this Mac's
/// model only — no text leaves the machine.
nonisolated enum SourceAnalysis {

    @Generable
    struct Study {
        @Guide(description: "A summary of the work in three to six sentences, grounded in the text itself")
        var summary: String
        @Guide(description: "Five to ten short keywords or phrases naming what the work is about")
        var keywords: [String]
        @Guide(description: "Names of people mentioned in the text, as written, without titles; empty if none")
        var names: [String]
        @Guide(description: "Three to eight central concepts the work defines or leans on, each a short noun phrase")
        var concepts: [String]
    }

    /// The opening of the PDF, enough for a reading: pages from the
    /// front until the model's comfortable measure is full.
    static func openingText(ofPDFAt url: URL, limit: Int = 8000) -> String? {
        guard let pdf = PDFDocument(url: url) else { return nil }
        var text = ""
        var pageIndex = 0
        while pageIndex < pdf.pageCount, text.count < limit {
            text += (pdf.page(at: pageIndex)?.string ?? "") + "\n"
            pageIndex += 1
        }
        let trimmed = text.prefix(limit)
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed)
    }

    @concurrent
    static func study(_ text: String) async throws -> Study {
        let session = LanguageModelSession()
        let response = try await session.respond(
            to: "Read the opening of this work and describe it.\n\n\(text)",
            generating: Study.self)
        return response.content
    }
}

extension AppState {

    /// Whether a source has been studied: the Summary heading its
    /// study writes in.
    private func isStudied(_ doc: LiquidDoc) -> Bool {
        (doc.body ?? []).contains { $0.heading == 2 && $0.text == "Summary" }
    }

    /// The source's PDF on this Mac, resolved like Open PDF: the
    /// granted Reader Library first, the recorded folder second, a
    /// wrapped file beside the sidecar third.
    private func sourcePDFURL(for doc: LiquidDoc) -> URL? {
        var candidates: [URL] = []
        if let line = (doc.body ?? []).first(where: { $0.text.hasPrefix("PDF: ") })?.text {
            let rest = line.dropFirst("PDF: ".count)
            let name: String
            var folder: String?
            if let separator = rest.range(of: " — kept in ") {
                name = String(rest[..<separator.lowerBound])
                var recorded = String(rest[separator.upperBound...])
                if let suffix = recorded.range(of: " on the importing Mac") {
                    recorded = String(recorded[..<suffix.lowerBound])
                }
                folder = recorded
            } else {
                name = String(rest)
            }
            if let readerLibraryURL {
                candidates.append(readerLibraryURL.appendingPathComponent(name))
            }
            if let folder {
                candidates.append(URL(fileURLWithPath: folder).appendingPathComponent(name))
            }
        }
        if let wraps = doc.wraps {
            candidates.append(doc.fileURL.deletingLastPathComponent()
                .appendingPathComponent(wraps.file))
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Analyze New: every source not yet studied whose PDF this Mac
    /// can reach gets its summary, keywords, names, and concepts —
    /// written into the source document as readable paragraphs, the
    /// keywords, names, and concepts also joining its concept pool
    /// (names tagged person), where the Map and the views read them.
    /// One work at a time, quietly, on this Mac's own model.
    func analyzeNewSources() {
        guard !sourceAnalysisRunning else { return }
        guard SystemLanguageModel.default.availability == .available else {
            showNote("The on-device model is not available on this Mac — Apple Intelligence is required.")
            return
        }
        let candidates = sourceEntries
            .map(\.doc)
            .filter { !isStudied($0) }
            .compactMap { doc -> (doc: LiquidDoc, pdf: URL)? in
                guard let url = sourcePDFURL(for: doc) else { return nil }
                return (doc, url)
            }
        guard !candidates.isEmpty else {
            showNote("Every reachable source is already analyzed.")
            return
        }
        sourceAnalysisRunning = true
        sourceAnalysisProgress = AnalysisProgress(done: 0, total: candidates.count)
        Task {
            var studied = 0
            for (finished, candidate) in candidates.enumerated() {
                sourceAnalysisProgress = AnalysisProgress(done: finished,
                                                          total: candidates.count)
                guard let text = SourceAnalysis.openingText(ofPDFAt: candidate.pdf) else { continue }
                guard let study = try? await SourceAnalysis.study(text) else { continue }
                writeStudy(study, into: candidate.doc)
                studied += 1
            }
            if studied > 0 { index.rescan() }
            sourceAnalysisRunning = false
            sourceAnalysisProgress = nil
            showNote(studied == 0
                ? "No source could be analyzed — their PDFs had no readable text."
                : "\(studied) source\(studied == 1 ? "" : "s") analyzed.")
        }
    }

    /// The study, written in: Summary as readable paragraphs at the
    /// source's foot; keywords, names, and concepts as lines — and as
    /// Defined Concepts in the pool, names tagged person.
    private func writeStudy(_ study: SourceAnalysis.Study, into doc: LiquidDoc) {
        // The file as it stands now — the study must not undo an edit
        // made since the shelf was listed.
        guard let data = try? Data(contentsOf: doc.fileURL),
              var updated = try? LiquidDoc.decode(data: data, fileURL: doc.fileURL)
        else { return }
        var paragraphs = updated.body ?? []
        var counter = paragraphs.count
        func add(_ text: String, heading: Int? = nil) {
            counter += 1
            paragraphs.append(LiquidDoc.Paragraph(id: "p\(counter)", heading: heading, text: text))
        }
        let keywords = study.keywords.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let names = study.names.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let concepts = study.concepts.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        add("Summary", heading: 2)
        add(study.summary)
        add("This summary and the lines below were produced by the on-device model from the work's opening pages; the abstract above, where present, is the authors' own.")
        if !keywords.isEmpty { add("Keywords: " + keywords.joined(separator: ", ")) }
        if !names.isEmpty { add("Names mentioned: " + names.joined(separator: ", ")) }
        if !concepts.isEmpty { add("Concepts: " + concepts.joined(separator: ", ")) }
        updated.body = paragraphs
        var pool = updated.concepts
        let known = Set(pool.map { $0.name.lowercased() })
        for keyword in keywords where !known.contains(keyword.lowercased()) {
            pool.append(LiquidDoc.Concept(id: UUID().uuidString, name: keyword))
        }
        for concept in concepts where !known.contains(concept.lowercased()) {
            pool.append(LiquidDoc.Concept(id: UUID().uuidString, name: concept))
        }
        for name in names where !known.contains(name.lowercased()) {
            pool.append(LiquidDoc.Concept(id: UUID().uuidString, name: name, tag: "person"))
        }
        updated.concepts = pool
        try? updated.jsonData().write(to: updated.fileURL, options: .atomic)
    }
}
