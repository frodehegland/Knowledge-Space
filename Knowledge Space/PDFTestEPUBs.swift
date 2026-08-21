#if os(macOS)
import Foundation
import AppKit
import PDFKit

// Settings ▸ Library's testing tool: every PDF in the Reader Library
// converted to an Origami EPUB — "test-" before each name — into the
// EPUB Library, a real corpus for exercising the EPUB writer, importer,
// and reader. The test books are files on the shelf only; the community
// folder gains nothing unless a test book is imported from the shelf by
// hand, and Delete Test EPUBs clears the files and those imports both.

extension AppState {

    /// The batch: one EPUB per PDF, "test-<name>.epub" beside the
    /// other EPUBs. Files already made are skipped, so a stopped run
    /// resumes where it left off; a PDF without readable text is
    /// counted, never fatal. Reports each step through `progress` and
    /// returns the closing summary.
    func convertAllPDFsToTestEPUBs(progress: @escaping (String) -> Void) async -> String {
        guard let readerFolder = readerLibraryURL else {
            return "Grant the Reader Library first — the PDFs live there."
        }
        guard let epubFolder = epubLibraryURL else {
            return "Grant the EPUB Library first — the test EPUBs land there."
        }
        var pdfs: [URL] = []
        let enumerator = FileManager.default.enumerator(
            at: readerFolder, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension.lowercased() == "pdf" { pdfs.append(url) }
        }
        guard !pdfs.isEmpty else { return "The Reader Library holds no PDFs." }
        pdfs.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
            == .orderedAscending }
        var made = 0, skipped = 0, unreadable = 0
        var mintedIDs = Set<String>()
        for (position, pdf) in pdfs.enumerated() {
            let name = pdf.deletingPathExtension().lastPathComponent
            progress("\(position + 1) of \(pdfs.count) — \(name)")
            if Self.existingConversion(of: name, prefix: "test-",
                                       in: epubFolder) != nil {
                skipped += 1
                continue
            }
            // The id minted here, where the index can vouch it unused;
            // the reading and writing off this pane's thread. The name
            // carries the id after "--", the shelf's pairing form.
            let id = LiquidAddress.makeID(author: authorName, created: .now) {
                self.index.isIDTaken($0) || mintedIDs.contains($0)
            }
            mintedIDs.insert(id)
            let destination = epubFolder
                .appendingPathComponent("test-\(name)--\(id)")
                .appendingPathExtension("epub")
            let author = authorName
            let converted = await Task.detached {
                Self.writeTestEPUB(fromPDF: pdf, to: destination,
                                   id: id, author: author)
            }.value
            if converted { made += 1 } else { unreadable += 1 }
        }
        var parts = ["\(made) converted"]
        if skipped > 0 { parts.append("\(skipped) already made") }
        if unreadable > 0 { parts.append("\(unreadable) without readable text") }
        return "Done — " + parts.joined(separator: ", ") + "."
    }

    /// One chosen PDF through File ▸ PDF-EPUB…: converted to
    /// "<name>.epub" in the EPUB Library — title, author, date,
    /// journal, and cited references as best the PDF tells them —
    /// imported and opened, and the PDF itself moved home to the
    /// Reader Library.
    func importPDFAsEPUB(from url: URL) {
        guard let epubFolder = epubLibraryURL else {
            showNote("Grant the EPUB Library first (Settings ▸ Library) — the converted EPUB lands there.")
            return
        }
        _ = url.startAccessingSecurityScopedResource()
        let name = url.deletingPathExtension().lastPathComponent
        // "<stem>--<id>.epub": the tail after "--" is how the shelf
        // pairs a file with its document; the stem keeps it readable.
        if let already = Self.existingConversion(of: name, prefix: "", in: epubFolder) {
            importOrigamiEPUB(from: already, openWhenReady: true)
            movePDFHome(url)
            return
        }
        let id = LiquidAddress.makeID(author: authorName, created: .now) {
            self.index.isIDTaken($0)
        }
        let destination = epubFolder
            .appendingPathComponent("\(name)--\(id)")
            .appendingPathExtension("epub")
        let author = authorName
        showNote("Converting \u{201C}\(name)\u{201D}\u{2026}")
        Task {
            let converted = await Task.detached {
                Self.writeTestEPUB(fromPDF: url, to: destination,
                                   id: id, author: author)
            }.value
            guard converted else {
                showNote("\u{201C}\(name)\u{201D} has no readable text — nothing to convert.")
                return
            }
            importOrigamiEPUB(from: destination, openWhenReady: true)
            movePDFHome(url)
        }
    }

    /// A conversion made earlier for this PDF — any
    /// "<prefix><stem>--<id>.epub" in the folder.
    nonisolated static func existingConversion(of stem: String, prefix: String,
                                               in folder: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        return files.first {
            $0.pathExtension.lowercased() == "epub"
                && $0.lastPathComponent.hasPrefix("\(prefix)\(stem)--")
        }
    }

    /// A converted PDF comes home to the Reader Library — unless it
    /// already lives there, no Reader Library is granted, or a file
    /// of its name already stands (the original then stays where it
    /// was; nothing is ever overwritten).
    private func movePDFHome(_ pdf: URL) {
        guard let reader = readerLibraryURL else { return }
        let standardized = pdf.standardizedFileURL.path
        guard !standardized.hasPrefix(reader.standardizedFileURL.path + "/") else { return }
        let destination = reader.appendingPathComponent(pdf.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        try? FileManager.default.moveItem(at: pdf, to: destination)
    }

    /// Several chosen PDFs — or a folder's worth — through File ▸
    /// PDF-EPUB…: each converted to "<name>.epub" in the EPUB Library
    /// with all the metadata the PDF gives, imported, and the PDF
    /// moved home to the Reader Library. An already-converted file
    /// imports as it stands.
    func importPDFsAsEPUBs(_ pdfs: [URL]) {
        guard !pdfs.isEmpty else { return }
        guard let epubFolder = epubLibraryURL else {
            showNote("Grant the EPUB Library first (Settings ▸ Library) — the converted EPUBs land there.")
            return
        }
        let author = authorName
        Task {
            var made = 0
            var unreadable = 0
            var mintedIDs = Set<String>()
            for (position, pdf) in pdfs.enumerated() {
                _ = pdf.startAccessingSecurityScopedResource()
                let name = pdf.deletingPathExtension().lastPathComponent
                showNote("Converting \(position + 1) of \(pdfs.count) — \(name)\u{2026}")
                if let already = Self.existingConversion(of: name, prefix: "",
                                                         in: epubFolder) {
                    importOrigamiEPUB(from: already)
                    movePDFHome(pdf)
                    made += 1
                    continue
                }
                let id = LiquidAddress.makeID(author: author, created: .now) {
                    self.index.isIDTaken($0) || mintedIDs.contains($0)
                }
                mintedIDs.insert(id)
                let destination = epubFolder
                    .appendingPathComponent("\(name)--\(id)")
                    .appendingPathExtension("epub")
                let converted = await Task.detached {
                    Self.writeTestEPUB(fromPDF: pdf, to: destination,
                                       id: id, author: author)
                }.value
                if converted {
                    made += 1
                    importOrigamiEPUB(from: destination)
                    movePDFHome(pdf)
                } else {
                    unreadable += 1
                }
            }
            showNote("Converted and imported \(made) of \(pdfs.count) PDFs"
                     + (unreadable > 0 ? " — \(unreadable) had no readable text." : "."))
        }
    }

    /// One PDF into one Origami EPUB: the text page by page (the
    /// Visual-Meta appendix stripped — it is metadata, not reading),
    /// the title from Visual-Meta, the PDF's own metadata, or the
    /// file's name, and the pages' lines gathered back into
    /// paragraphs. False where the PDF offers no usable text — a scan
    /// without a text layer, an empty file.
    private nonisolated static func writeTestEPUB(
        fromPDF pdfURL: URL, to destination: URL,
        id: String, author: String) -> Bool {
        guard let pdf = PDFDocument(url: pdfURL) else { return false }
        let rawText = (0..<pdf.pageCount)
            .compactMap { pdf.page(at: $0)?.string }
            .joined(separator: "\n\n")
        var text = rawText
        if let start = text.range(of: VisualMeta.startMarker, options: .backwards) {
            text = String(text[..<start.lowerBound])
        }
        let paragraphs = paragraphize(text)
        let words = paragraphs.reduce(0) { $0 + $1.split(separator: " ").count }
        guard words >= 50 else { return false }
        func trimmedAttribute(_ key: PDFDocumentAttribute) -> String? {
            (pdf.documentAttributes?[key] as? String)
                .flatMap { value -> String? in
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
        }
        let harvest = PDFVisualMeta.harvest(inPDFAt: pdfURL)
        let title = harvest?.resolvedTitle
            ?? trimmedAttribute(.titleAttribute)
            ?? pdfURL.deletingPathExtension().lastPathComponent
        // The work's own author — the one to cite — from Visual-Meta,
        // else the PDF's metadata; the app's user only mints the
        // address, never signs another's words.
        let recordAuthors = harvest.map(\.record.displayAuthors)
            .flatMap { $0.isEmpty ? nil : $0 }
        let workAuthor = recordAuthors
            ?? trimmedAttribute(.authorAttribute)
            ?? "Unknown"
        _ = author   // the address bears the importer's initials; the work keeps its own name
        var body: [LiquidDoc.Paragraph] = []
        for (index, paragraphText) in paragraphs.enumerated() {
            body.append(LiquidDoc.Paragraph(id: "p\(index + 1)", heading: nil,
                                            text: paragraphText))
        }
        var doc = LiquidDoc(format: LiquidDoc.knownFormat,
                            id: id,
                            title: title,
                            author: workAuthor,
                            created: .now,
                            body: body,
                            links: [],
                            wraps: nil,
                            fileURL: destination)
        doc.documentType = LiquidDoc.DocumentType.source.rawValue
        if let year = harvest?.record.year, !year.isEmpty,
           let date = LiquidDate(isoString: year) {
            doc.date = date
        }
        // The PDF's own Visual-Meta record rides along whole as the
        // book's self-reference — its journal or booktitle names the
        // shelf the work belongs to, here and after import.
        if let record = harvest?.record {
            doc.references = [LiquidDoc.Reference(id: id, bibtex: record.raw)]
        }
        // The cited works follow — Visual-Meta's verbatim BibTeX where
        // the PDF carries a references block, else mined from the
        // References section of the text itself. Who a paper cites is
        // half the demonstration.
        let cited = citedReferences(inVisualMetaOf: rawText, orBody: text)
        doc.references += cited.filter { $0.id != id }
        do {
            try OrigamiEPUBExporter.write(
                doc, to: destination,
                generator: "Knowledge Space PDF test conversion")
            return true
        } catch {
            return false
        }
    }

    /// The cited works, as best the PDF tells them. The gold path is
    /// Visual-Meta's @{references} block — verbatim BibTeX, adopted
    /// whole. Without one, the References section is mined from the
    /// text itself. Errors are survivable by design: a mangled entry
    /// is still a legible record, its raw line kept in `note`.
    private nonisolated static func citedReferences(
        inVisualMetaOf rawText: String, orBody body: String) -> [LiquidDoc.Reference] {
        if let start = rawText.range(of: "@{references-start}", options: .backwards),
           let end = rawText.range(of: "@{references-end}", options: .backwards),
           start.upperBound < end.lowerBound {
            let block = String(rawText[start.upperBound..<end.lowerBound])
                .replacingOccurrences(of: "\u{FFFC}", with: "")
            let records = BibTeXRecord.records(in: block)
            if !records.isEmpty {
                var seen = Set<String>()
                return records.enumerated().compactMap { position, record in
                    let id = record.key.isEmpty ? "cited-\(position + 1)" : record.key
                    guard seen.insert(id).inserted else { return nil }
                    return LiquidDoc.Reference(id: id, bibtex: record.raw)
                }
            }
        }
        return minedReferences(from: body)
    }

    /// The References section mined from plain text — Augmented
    /// Library's deterministic pass, carried over: the heading found
    /// in the closing pages, entries split on their numbering (else
    /// blank lines), each anchored by what patterns can prove.
    private nonisolated static func minedReferences(from body: String) -> [LiquidDoc.Reference] {
        let lower = body.lowercased()
        var headingRange: Range<String.Index>?
        for heading in ["\nreferences", "\nbibliography", "\nworks cited"] {
            if let found = lower.range(of: heading, options: .backwards),
               headingRange.map({ found.lowerBound > $0.lowerBound }) ?? true {
                headingRange = found
            }
        }
        guard let headingRange else { return [] }
        // Only a heading in the closing stretch reads as the
        // bibliography — "references" mid-paper is just a word.
        let position = lower.distance(from: lower.startIndex,
                                      to: headingRange.lowerBound)
        guard position > lower.count * 2 / 5 else { return [] }
        let section = String(body[headingRange.upperBound...])
        var raws: [String] = []
        let ns = section as NSString
        if let numbering = try? NSRegularExpression(pattern: #"\n\s*\[?\d{1,3}[\].]\s"#) {
            let matches = numbering.matches(
                in: section, range: NSRange(location: 0, length: ns.length))
            if matches.count >= 3 {
                var bounds = matches.map(\.range.location)
                bounds.append(ns.length)
                for index in 0..<(bounds.count - 1) {
                    raws.append(ns.substring(
                        with: NSRange(location: bounds[index],
                                      length: bounds[index + 1] - bounds[index])))
                }
            }
        }
        if raws.isEmpty { raws = section.components(separatedBy: "\n\n") }
        var references: [LiquidDoc.Reference] = []
        for raw in raws {
            guard references.count < 300 else { break }
            let entry = raw.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard entry.count >= 24, entry.count <= 1200 else { continue }
            let key = "cited-\(references.count + 1)"
            references.append(LiquidDoc.Reference(
                id: key, bibtex: minedBibTeX(raw: entry, key: key)))
        }
        return references
    }

    /// One mined entry as BibTeX: DOI and year by pattern, a quoted
    /// title where one stands, the raw entry whole in `note` so
    /// nothing is ever lost to a bad parse.
    private nonisolated static func minedBibTeX(raw: String, key: String) -> String {
        func escaped(_ value: String) -> String {
            value.replacingOccurrences(of: "{", with: "(")
                .replacingOccurrences(of: "}", with: ")")
        }
        var fields: [String] = []
        if let range = raw.range(of: #"[“"]([^”"]{8,})[”"]"#, options: .regularExpression) {
            let title = String(raw[range])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\u{201C}\u{201D}\""))
            fields.append("  title = {\(escaped(title))}")
        }
        if let range = raw.range(of: #"\b(19|20)\d\d\b"#, options: .regularExpression) {
            fields.append("  year = {\(raw[range])}")
        }
        if let range = raw.range(of: #"10\.\d{4,9}/[-._;()/:A-Za-z0-9]+"#,
                                 options: .regularExpression) {
            fields.append("  doi = {\(raw[range])}")
        }
        fields.append("  note = {\(escaped(raw))}")
        return "@misc{\(key),\n" + fields.joined(separator: ",\n") + ",\n}"
    }

    /// The pages' visual lines back into reading paragraphs: a blank
    /// line breaks; without blank lines a paragraph also closes at a
    /// sentence's end once it has grown long — a PDF page often
    /// arrives as bare wrapped lines.
    private nonisolated static func paragraphize(_ text: String) -> [String] {
        var paragraphs: [String] = []
        var current: [String] = []
        func close() {
            let joined = current.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { paragraphs.append(joined) }
            current = []
        }
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                close()
                continue
            }
            current.append(line)
            let grown = current.reduce(0) { $0 + $1.count }
            if grown > 900,
               line.hasSuffix(".") || line.hasSuffix("?") || line.hasSuffix("!") {
                close()
            }
        }
        close()
        return paragraphs
    }

    /// The one-shot backfill: every imported EPUB work whose head
    /// record is the bare machine-synthesized shape gets it re-derived
    /// from its companion EPUB — the carried record where the package
    /// holds one, else today's synthesis, publisher and all. A head
    /// that differs from the machine shape is someone's word, and
    /// stands untouched. Each write merges onto the file's current
    /// bytes, never a stale copy.
    func refreshShelfRecords(progress: @escaping (String) -> Void) async -> String {
        // First, the pairing repair: an EPUB written under a plain
        // name cannot be read back from its name alone, so its
        // imported document vanishes from the shelf. Any library EPUB
        // the pairing has lost is asked for its own origami-id; where
        // that names a shelved document, the file is renamed into the
        // "slug--id" form the pairing reads. Files already paired are
        // never touched.
        var repaired = 0
        if let epubFolder = epubLibraryURL {
            let files = ((try? FileManager.default.contentsOfDirectory(
                at: epubFolder, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])) ?? [])
                .filter { $0.pathExtension.lowercased() == "epub" }
            for file in files
            where pairedEPUBDocument(forFileName: file.lastPathComponent) == nil {
                progress("Pairing — \(file.lastPathComponent)")
                let carried: String? = await Task.detached {
                    Self.origamiID(inEPUBAt: file)
                }.value
                guard let carried,
                      let doc = index.allByID[LiquidAddress.canonical(carried)]?.doc
                else { continue }
                let slug = LiquidDoc.fileSlug(from: doc.title)
                let renamed = epubFolder.appendingPathComponent(
                    slug.isEmpty ? "\(doc.id).epub" : "\(slug)--\(doc.id).epub")
                guard !FileManager.default.fileExists(atPath: renamed.path)
                else { continue }
                try? FileManager.default.moveItem(at: file, to: renamed)
                repaired += 1
            }
        }
        let works = index.allByID.values.map(\.doc)
            .filter { epubCompanionURL(for: $0) != nil }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title)
                == .orderedAscending }
        guard !works.isEmpty else {
            return repaired > 0
                ? "Done — \(repaired) EPUBs re-paired with their documents."
                : "No imported EPUB works to refresh."
        }
        var refreshed = 0, stood = 0, unreadable = 0
        for (position, doc) in works.enumerated() {
            progress("\(position + 1) of \(works.count) — \(doc.title)")
            guard let companion = epubCompanionURL(for: doc) else { continue }
            let head = doc.references.first(where: { $0.id == doc.id })
            if let head, !Self.isMachineShapedRecord(head.bibtex, id: doc.id) {
                stood += 1
                continue
            }
            let parsed: OrigamiEPUBImporter.ImportResult? = await Task.detached {
                try? OrigamiEPUBImporter.importDocument(at: companion)
            }.value
            guard let result = parsed else {
                unreadable += 1
                continue
            }
            let fresh = result.references.first(where: { $0.id == doc.id })?.bibtex
                ?? Self.selfBibTeX(id: doc.id, title: result.title,
                                   author: result.author, date: result.date,
                                   publisher: result.publisher)
            if fresh == head?.bibtex {
                stood += 1
                continue
            }
            let docID = doc.id
            if mutateNoteFile(doc, { updated in
                updated.references = [LiquidDoc.Reference(id: docID, bibtex: fresh)]
                    + updated.references.filter { $0.id != docID }
            }) {
                refreshed += 1
            } else {
                unreadable += 1
            }
        }
        var parts = ["\(refreshed) refreshed", "\(stood) already told their story"]
        if repaired > 0 { parts.append("\(repaired) re-paired") }
        if unreadable > 0 { parts.append("\(unreadable) unreadable") }
        return "Done — " + parts.joined(separator: ", ") + "."
    }

    /// The origami-id an EPUB's own origami.json carries — the
    /// document it stands for, read from the package rather than
    /// guessed from the file's name.
    private nonisolated static func origamiID(inEPUBAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let zip = try? ZipReader(data: data) else { return nil }
        let json = zip.entry("OEBPS/origami.json")
            ?? zip.entries.first { $0.key.hasSuffix("origami.json") }?.value
        guard let json,
              let object = (try? JSONSerialization.jsonObject(with: json))
                  as? [String: Any],
              let document = object["document"] as? [String: Any]
        else { return nil }
        return document["origami-id"] as? String
    }

    /// A head record the machine wrote — "@book{<id>," carrying only
    /// the synthesized fields. Anything else is someone's word.
    private nonisolated static func isMachineShapedRecord(_ bibtex: String,
                                                          id: String) -> Bool {
        guard let record = BibTeXRecord.parse(bibtex) else { return true }
        guard record.entryType.lowercased() == "book", record.key == id
        else { return false }
        let machineFields: Set<String> = ["title", "author", "year", "publisher"]
        return Set(record.fields.keys.map { $0.lowercased() })
            .isSubset(of: machineFields)
    }

    /// One work off the shelf, whole: the EPUB file and — for an
    /// imported work — its document and annotation sidecar move to
    /// the Trash, asked about every time like the app's other
    /// deliberate deletions. The Trash keeps the words.
    /// Returns whether the work was moved — a cancelled alert leaves
    /// everything, selection included, exactly as it stood.
    @discardableResult
    func trashEPUBWork(epub: URL?, doc: LiquidDoc?) -> Bool {
        guard epub != nil || doc != nil else { return false }
        let title = doc?.title
            ?? epub?.deletingPathExtension().lastPathComponent
            ?? "this work"
        var parts: [String] = []
        if epub != nil { parts.append("the EPUB file") }
        if doc != nil {
            parts.append("its document — which leaves the shared community folder for everyone who syncs it")
        }
        let alert = NSAlert()
        alert.messageText = "Move \u{201C}\(title)\u{201D} to the Trash?"
        alert.informativeText = "This moves \(parts.joined(separator: " and ")) to the Trash, where the words are kept."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        if let doc {
            let sidecar = AnnotationStore.fileURL(
                for: doc.id, in: doc.fileURL.deletingLastPathComponent())
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try? FileManager.default.trashItem(at: sidecar, resultingItemURL: nil)
            }
            try? FileManager.default.trashItem(at: doc.fileURL, resultingItemURL: nil)
            if selectedDocID == doc.id { selectedDocID = nil }
        }
        if let epub {
            try? FileManager.default.trashItem(at: epub, resultingItemURL: nil)
        }
        index.rescan()
        showNote("\u{201C}\(title)\u{201D} moved to the Trash.")
        return true
    }

    /// The shelf swept of rubbish: every EPUB in the EPUB Library
    /// whose body reads as missing or only a few characters — judged
    /// by the same importer that would read it, so "rubbish" means
    /// exactly "nothing here to read". A package the importer cannot
    /// parse at all only counts as rubbish when it is a "test-" file
    /// of our own making — a foreign EPUB that merely defeats the
    /// parser is not for us to delete. Rubbish files go to the Trash,
    /// along with any documents imported from them; one confirmation
    /// for the lot.
    func deleteRubbishEPUBs() async {
        guard let epubFolder = epubLibraryURL else {
            showNote("No EPUB Library is granted.")
            return
        }
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: epubFolder, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension.lowercased() == "epub" }
        guard !files.isEmpty else {
            showNote("The EPUB Library holds no EPUBs.")
            return
        }
        // Reading every package is work for another thread.
        let rubbish: [URL] = await Task.detached {
            files.filter { url in
                guard let result = try? OrigamiEPUBImporter.importDocument(at: url)
                else {
                    return url.lastPathComponent.hasPrefix("test-")
                }
                let characters = result.body.reduce(0) {
                    $0 + $1.text.trimmingCharacters(in: .whitespacesAndNewlines).count
                }
                return characters < 200
            }
        }.value
        guard !rubbish.isEmpty else {
            showNote("No rubbish — all \(files.count) EPUBs carry readable text.")
            return
        }
        let rubbishNames = Set(rubbish.map(\.lastPathComponent))
        let importedDocs = index.allByID.values
            .map(\.doc)
            .filter { doc in
                guard let companion = epubCompanionURL(for: doc) else { return false }
                return rubbishNames.contains(companion.lastPathComponent)
            }
        let named = rubbish.prefix(5).map(\.lastPathComponent)
            .joined(separator: "\n")
        let more = rubbish.count > 5 ? "\n…and \(rubbish.count - 5) more." : ""
        let alert = NSAlert()
        alert.messageText = "Delete \(rubbish.count) rubbish EPUBs?"
        alert.informativeText = "These read as empty — no body text, or only a few characters:\n\(named)\(more)\n\nThey move to the Trash"
            + (importedDocs.isEmpty
               ? "."
               : ", along with \(importedDocs.count) documents imported from them — those leave the shared community folder for everyone who syncs it.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for doc in importedDocs {
            let sidecar = AnnotationStore.fileURL(
                for: doc.id, in: doc.fileURL.deletingLastPathComponent())
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try? FileManager.default.trashItem(at: sidecar, resultingItemURL: nil)
            }
            try? FileManager.default.trashItem(at: doc.fileURL, resultingItemURL: nil)
            if selectedDocID == doc.id { selectedDocID = nil }
        }
        for file in rubbish {
            try? FileManager.default.trashItem(at: file, resultingItemURL: nil)
        }
        index.rescan()
        showNote("\(rubbish.count) rubbish EPUBs and \(importedDocs.count) imported documents moved to the Trash.")
    }

    /// The group gone in one act: every "test-" EPUB in the EPUB
    /// Library to the Trash — and with them any documents minted by
    /// importing one, whose files leave the shared community folder
    /// (the Trash keeps them; annotation sidecars go along). One
    /// confirmation for the lot.
    func deleteTestEPUBs() {
        guard let epubFolder = epubLibraryURL else {
            showNote("No EPUB Library is granted.")
            return
        }
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: epubFolder, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? [])
            .filter {
                $0.pathExtension.lowercased() == "epub"
                    && $0.lastPathComponent.hasPrefix("test-")
            }
        let importedDocs = index.allByID.values
            .map(\.doc)
            .filter { doc in
                epubCompanionURL(for: doc)?.lastPathComponent
                    .hasPrefix("test-") == true
            }
        guard !files.isEmpty || !importedDocs.isEmpty else {
            showNote("No test EPUBs to delete.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete all test EPUBs?"
        alert.informativeText = "\(files.count) test EPUBs move to the Trash"
            + (importedDocs.isEmpty
               ? "."
               : ", along with \(importedDocs.count) documents imported from them — those leave the shared community folder for everyone who syncs it.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for doc in importedDocs {
            let sidecar = AnnotationStore.fileURL(
                for: doc.id, in: doc.fileURL.deletingLastPathComponent())
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try? FileManager.default.trashItem(at: sidecar, resultingItemURL: nil)
            }
            try? FileManager.default.trashItem(at: doc.fileURL, resultingItemURL: nil)
            if selectedDocID == doc.id { selectedDocID = nil }
        }
        for file in files {
            try? FileManager.default.trashItem(at: file, resultingItemURL: nil)
        }
        index.rescan()
        showNote("\(files.count) test EPUBs and \(importedDocs.count) imported documents moved to the Trash.")
    }
}
#endif
