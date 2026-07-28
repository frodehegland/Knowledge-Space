import Foundation
import PDFKit
import FoundationModels
#if os(macOS)
import AppKit
#endif

// The Digest: a granted folder of the user's own documents — the
// Documents directory, or any folder they choose — distilled into
// Origami notes. One digest per document: an on-device summary and
// keywords where the model can read it, the file's own words where it
// cannot, and always the way back — Open Original hands the file to
// whatever app owns it. Digests live in their own "Digest" folder
// inside the community folder, wear their own documentType, and stay
// out of every other view; only the sidebar's Digest section shows
// them. The originals are read, never touched.

extension LiquidDoc {
    /// A digest: the distillation of one file from the granted
    /// documents folder. Its own kind, so every list can keep it out
    /// unless it is the Digest list itself.
    nonisolated var isDigest: Bool {
        documentType == DocumentType.digest.rawValue
    }
}

/// The Digest's reading of a file: extraction by kind. The model's
/// study itself is the sources' own (`SourceAnalysis.Study`) — summary,
/// keywords, names, concepts — so a digest speaks the same language as
/// the shelf, and its names join the same interactions.
nonisolated enum DigestStudy {

    /// The file kinds the Digest can read words out of.
    static let readableExtensions: Set<String> =
        ["pdf", "txt", "md", "markdown", "text", "rtf", "rtfd", "html", "htm", "docx"]

    /// The file's opening words, by whatever door its kind offers:
    /// PDFKit for PDFs, plain reading for text, AttributedString's
    /// importers for RTF, HTML, and Word files. Nil when the kind
    /// holds no reachable words.
    static func extractText(at url: URL, limit: Int = 8000) -> String? {
        let ext = url.pathExtension.lowercased()
        var text: String?
        switch ext {
        case "pdf":
            text = SourceAnalysis.openingText(ofPDFAt: url, limit: limit)
        case "txt", "md", "markdown", "text":
            text = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .isoLatin1))
        case "rtf", "rtfd", "html", "htm", "docx":
            #if os(macOS)
            text = (try? NSAttributedString(url: url, options: [:],
                                            documentAttributes: nil))?.string
            #endif
        default:
            return nil
        }
        guard let text else { return nil }
        let trimmed = text.prefix(limit)
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed)
    }
}

// MARK: - The Digest on AppState

extension AppState {

    static let digestFolderName = "Digest"
    private static let digestBookmarkKey = "digestSourceBookmark"

    /// The Digest's home: a "Digest" folder inside the community
    /// folder, made on first need.
    var digestsFolderURL: URL? {
        guard let folder = index.folderURL else { return nil }
        let url = folder.appendingPathComponent(Self.digestFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Grants the folder the Digest distills — remembered like the
    /// Reader Library, scanned at once.
    func chooseDigestSource(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        #if os(macOS)
        let data = try? url.bookmarkData(options: .withSecurityScope,
                                         includingResourceValuesForKeys: nil,
                                         relativeTo: nil)
        #else
        let data = try? url.bookmarkData()
        #endif
        UserDefaults.standard.set(data, forKey: Self.digestBookmarkKey)
        digestSourceURL = url
        scanDigestSource()
    }

    /// Re-opens the granted folder at launch.
    func restoreDigestSource() {
        guard let data = UserDefaults.standard.data(forKey: Self.digestBookmarkKey) else { return }
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
        digestSourceURL = url
    }

    /// Walks the granted folder and digests what is new or changed:
    /// extraction and the model's reading run off the main actor, one
    /// file at a time, each digest appearing in the list as it lands.
    /// Files already digested and unchanged since are left alone.
    func scanDigestSource() {
        guard let source = digestSourceURL else {
            showNote("Choose a folder to digest first — Settings ▸ Library.")
            return
        }
        guard let home = digestsFolderURL else {
            showNote("Choose a community folder first — digests live in its Digest folder.")
            return
        }
        guard !digestScanRunning else { return }
        digestScanRunning = true

        // What stands already: original path → (digest id, digested
        // when, and whether it predates the full study — a slim digest
        // without sections is re-made rather than skipped).
        var existing: [String: (id: String, made: Date, slim: Bool)] = [:]
        for entry in index.timeline where entry.doc.isDigest {
            if let path = Self.digestOriginalPath(of: entry.doc) {
                let slim = !(entry.doc.body ?? []).contains { $0.heading == 2 }
                existing[path] = (entry.id, entry.doc.created, slim)
            }
        }

        // The walk itself is file work — off the main actor.
        Task {
            let candidates = await Task.detached(priority: .userInitiated) {
                Self.digestCandidates(in: source)
            }.value

            let work = candidates.filter { candidate in
                guard let stood = existing[candidate.url.path] else { return true }
                return candidate.modified > stood.made || stood.slim
            }
            guard !work.isEmpty else {
                digestScanRunning = false
                digestProgress = nil
                showNote(candidates.isEmpty
                    ? "Nothing to digest — no readable documents in the folder."
                    : "The Digest already matches the folder — \(candidates.count) documents, all digested.")
                return
            }
            digestProgress = AnalysisProgress(done: 0, total: work.count)
            var made = 0
            for (finished, candidate) in work.enumerated() {
                digestProgress = AnalysisProgress(done: finished, total: work.count)
                let text = await Task.detached(priority: .utility) {
                    DigestStudy.extractText(at: candidate.url)
                }.value
                var study: SourceAnalysis.Study?
                if let text, SystemLanguageModel.default.availability == .available {
                    study = try? await SourceAnalysis.study(text)
                }
                writeDigest(of: candidate, study: study, opening: text,
                            replacing: existing[candidate.url.path]?.id, in: home)
                made += 1
                index.rescan()
            }
            digestScanRunning = false
            digestProgress = nil
            showNote("Digested \(made) document\(made == 1 ? "" : "s") — they stand in the sidebar's Digest section.")
        }
    }

    /// Every readable file under the folder, hidden files and packages
    /// skipped, with its modification date.
    nonisolated private static func digestCandidates(in folder: URL)
        -> [(url: URL, modified: Date)] {
        var found: [(URL, Date)] = []
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        for case let url as URL in enumerator {
            guard DigestStudy.readableExtensions.contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            found.append((url, modified))
        }
        return found.sorted { $0.1 > $1.1 }
    }

    /// One digest written (or rewritten, when the original changed):
    /// the model's full study where it read the words — a paragraph
    /// summary, keywords, names, concepts, the terms joining the
    /// concept pool so they interact like every name in Knowledge
    /// Space — then a long opening of the document's own words, and
    /// always the pointer home.
    private func writeDigest(of candidate: (url: URL, modified: Date),
                             study: SourceAnalysis.Study?,
                             opening: String?,
                             replacing existingID: String?,
                             in home: URL) {
        let created = Date.now
        let id = existingID
            ?? LiquidAddress.makeID(author: authorName, created: created) {
                self.index.isIDTaken($0)
            }
        var paragraphs: [LiquidDoc.Paragraph] = []
        var next = 1
        func add(_ text: String, heading: Int? = nil) {
            paragraphs.append(LiquidDoc.Paragraph(id: "p\(next)", heading: heading, text: text))
            next += 1
        }
        let keywords = (study?.keywords ?? []).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let names = (study?.names ?? []).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let concepts = (study?.concepts ?? []).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let study {
            add("Summary", heading: 2)
            add(study.summary)
            add("This summary and the lines below were produced by the on-device model from the document's opening.")
            if !keywords.isEmpty { add("Keywords: " + keywords.joined(separator: ", ")) }
            if !names.isEmpty { add("Names mentioned: " + names.joined(separator: ", ")) }
            if !concepts.isEmpty { add("Concepts: " + concepts.joined(separator: ", ")) }
        }
        if let opening {
            // The document's own voice: a long opening, so the digest
            // reads as the thing itself and not only as its label.
            add("Opening", heading: 2)
            let words = opening.split(whereSeparator: \.isWhitespace)
            add(words.prefix(250).joined(separator: " ") + (words.count > 250 ? " …" : ""))
        } else if study == nil {
            add("No readable words in this kind of file — the digest stands as a pointer.")
        }
        // The way home, machine-readable: Open Original parses this.
        add("File: \(candidate.url.path)")

        var doc = LiquidDoc(format: LiquidDoc.knownFormat,
                            id: id,
                            title: candidate.url.deletingPathExtension().lastPathComponent,
                            author: authorName,
                            created: created,
                            body: paragraphs,
                            links: [],
                            wraps: nil,
                            fileURL: home.appendingPathComponent(id)
                                .appendingPathExtension(LiquidDoc.fileExtension))
        doc.documentType = LiquidDoc.DocumentType.digest.rawValue
        // The study's terms join the concept pool, names tagged person —
        // the same pool the sources fill, so the reader offers the same
        // interactions everywhere.
        var pool: [LiquidDoc.Concept] = []
        var known = Set<String>()
        for keyword in keywords + concepts where known.insert(keyword.lowercased()).inserted {
            pool.append(LiquidDoc.Concept(id: UUID().uuidString, name: keyword))
        }
        for name in names where known.insert(name.lowercased()).inserted {
            pool.append(LiquidDoc.Concept(id: UUID().uuidString, name: name, tag: "person"))
        }
        doc.concepts = pool
        // The digest wears the original's day, so the list orders by
        // the documents' own lives.
        let parts = Calendar.current.dateComponents([.year, .month, .day],
                                                    from: candidate.modified)
        if let year = parts.year {
            doc.date = LiquidDate(year: year, month: parts.month, day: parts.day)
        }
        try? doc.jsonData().write(to: doc.fileURL, options: .atomic)
    }

    /// The digest's original, parsed from its pointer line.
    nonisolated static func digestOriginalPath(of doc: LiquidDoc) -> String? {
        guard let line = (doc.body ?? []).last(where: { $0.text.hasPrefix("File: ") })
        else { return nil }
        let path = String(line.text.dropFirst("File: ".count))
            .trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }

    /// Open Original: the file handed to whatever app owns it.
    func openDigestOriginal(_ doc: LiquidDoc) {
        guard let path = Self.digestOriginalPath(of: doc) else {
            showNote("This digest carries no pointer to its original.")
            return
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            showNote("The original is not where the digest points — moved or renamed since: \(url.lastPathComponent)")
            return
        }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }
}
