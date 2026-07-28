import Foundation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

// Transcripts, the Digital Letters way: a meeting's words as one
// document whose every statement is addressable and every speaker
// ascribable. Import parses "Speaker Name: what they said" (Zoom-style
// timestamps tolerated and dropped) into paragraphs carrying the
// `speaker` field; every speaker becomes known to the system — a
// contact record starts for any name People does not yet answer to —
// and in the reader each name is a menu: see the person in any view,
// or copy their words into notes that cite their way back, statement
// by statement.

/// Imports meeting transcripts: plain text where each statement is
/// "Speaker Name: what they said". Zoom-style timestamps are tolerated —
/// "Name (00:12:34): …" and "[00:12:34] Name: …" — and dropped. Each
/// statement becomes one paragraph whose text keeps the "Name: " prefix
/// (plain-text readers lose nothing) and whose `speaker` field carries the
/// attribution structurally. Lines that name no speaker continue the
/// statement above them. Ported from Digital Letters; the parsing must
/// stay identical so both apps read the same files the same way.
nonisolated enum TranscriptImporter {

    struct Result {
        let title: String
        /// The meeting's day, when the transcript opens with a date line
        /// ("6 July 26") or the file is named by date ("6 July 2026.rtf").
        let date: LiquidDate?
        let speakers: [String]           // in order of first appearance
        let body: [LiquidDoc.Paragraph]
    }

    /// The date forms meeting transcripts actually open with:
    /// "6 July 26", "6 July 2026", "July 6, 2026", "2026-07-06".
    static func parseDate(_ string: String) -> LiquidDate? {
        let trimmed = string.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        for format in ["d MMMM yyyy", "d MMMM yy", "MMMM d, yyyy", "MMMM d yyyy",
                       "d MMM yyyy", "d MMM yy", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            guard let date = formatter.date(from: trimmed) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            guard var year = parts.year, let month = parts.month, let day = parts.day else { continue }
            // "6 July 26" means 2026 here: these are meeting dates, and a
            // bare two-digit year takes the standard century pivot.
            if year < 100 { year += year <= 49 ? 2000 : 1900 }
            return LiquidDate(isoString: String(format: "%04d-%02d-%02d", year, month, day))
        }
        return nil
    }

    /// A line "Name: text" names a speaker when the part before the colon
    /// is one to four words, each starting with a letter, containing no
    /// sentence punctuation — "Mark Anderson:" yes, "Note:" is also
    /// accepted alone but rejected by the sniffer's two-speaker minimum.
    private static let speakerLinePattern =
        /^(?:\[[0-9:.\-–— ]+\]\s*)?(?<name>\p{L}[\p{L}'’.\-]*(?:\s+\p{L}[\p{L}'’.\-]*){0,3})\s*(?:\([0-9:.\-–— ]+\))?\s*:\s*(?<statement>.*)$/

    private static func speakerMatch(in line: String) -> (name: String, statement: String)? {
        guard let match = line.wholeMatch(of: speakerLinePattern) else { return nil }
        let name = String(match.name).trimmingCharacters(in: .whitespaces)
        // A colon deep into a sentence is prose, not attribution.
        guard name.count <= 40 else { return nil }
        // A URL is not a speaker: "https://…" reads as name "https"
        // with a statement beginning "//".
        guard !match.statement.hasPrefix("//") else { return nil }
        return (name, String(match.statement).trimmingCharacters(in: .whitespaces))
    }

    /// Whether text reads as a transcript: most non-empty lines are
    /// attributed statements, and at least two speakers *recur* — real
    /// conversation alternates, while prose colon-prefixes ("Note:",
    /// "Warning:") appear once each.
    static func looksLikeTranscript(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 4 else { return false }
        let matches = lines.compactMap { speakerMatch(in: $0) }
        var counts: [String: Int] = [:]
        for match in matches { counts[match.name, default: 0] += 1 }
        let recurringSpeakers = counts.values.count { $0 >= 2 }
        return recurringSpeakers >= 2 && matches.count * 10 >= lines.count * 6
    }

    static func importText(_ text: String, fallbackTitle: String) -> Result {
        var speakers: [String] = []
        var statements: [(speaker: String?, text: String)] = []
        var date: LiquidDate?

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let (name, statement) = speakerMatch(in: line) {
                if !speakers.contains(name) { speakers.append(name) }
                statements.append((name, statement))
            } else if !statements.isEmpty, statements[statements.count - 1].speaker != nil {
                // Continuation of the statement above.
                statements[statements.count - 1].text += " " + line
            } else {
                // Preamble before the first speaker: a plain paragraph.
                statements.append((nil, line))
            }
        }

        // A transcript that opens with just a date ("6 July 26") is telling
        // us the meeting's day: it becomes the document's human date rather
        // than a body paragraph. The filename is the fallback teller.
        if let first = statements.first, first.speaker == nil,
           let opening = parseDate(first.text) {
            date = opening
            statements.removeFirst()
        } else {
            date = parseDate(fallbackTitle)
        }

        let body = statements.enumerated().map { index, statement in
            LiquidDoc.Paragraph(id: "p\(index + 1)",
                                heading: nil,
                                text: statement.speaker.map { "\($0): \(statement.text)" } ?? statement.text,
                                speaker: statement.speaker)
        }
        return Result(title: fallbackTitle, date: date, speakers: speakers, body: body)
    }
}

// MARK: - The process, on the library

extension AppState {

    #if os(macOS)
    /// File ▸ Import Transcript…: plain text or RTF, speaker names
    /// before statements. Each file becomes a transcript document in
    /// the community folder, and every speaker becomes known — a
    /// contact record starts for any name People does not answer to.
    func importTranscripts() {
        guard index.folderURL != nil else {
            showNote("Choose a library folder first — transcripts live there.")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.plainText, .rtf, .text]
        panel.message = "Choose meeting transcripts — plain text or RTF, speaker names before statements (“Mark Anderson: …”)."
        panel.prompt = "Import"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        var imported: [String] = []
        for url in panel.urls {
            guard let text = Self.readTranscriptText(at: url) else { continue }
            let parsed = TranscriptImporter.importText(
                text, fallbackTitle: url.deletingPathExtension().lastPathComponent)
            if let doc = adoptTranscript(parsed) {
                imported.append(doc.title)
            }
        }
        guard !imported.isEmpty else {
            showNote("Nothing imported — could not read the chosen files as text.")
            return
        }
        index.rescan()
        showNote("Imported \(imported.count) transcript\(imported.count == 1 ? "" : "s"): "
            + imported.joined(separator: ", "))
    }

    /// The file's words: UTF-8 plain text, or RTF unwrapped to plain.
    private static func readTranscriptText(at url: URL) -> String? {
        if url.pathExtension.lowercased() == "rtf",
           let attributed = try? NSAttributedString(
                url: url, options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil) {
            return attributed.string
        }
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) { return utf8 }
        return try? String(contentsOf: url, encoding: .isoLatin1)
    }
    #endif

    /// One parsed transcript written into the folder, its speakers made
    /// known to the system.
    private func adoptTranscript(_ parsed: TranscriptImporter.Result) -> LiquidDoc? {
        guard let folderURL = index.folderURL else { return nil }
        let created = Date.now
        let id = LiquidAddress.makeID(author: authorName, created: created) {
            self.index.isIDTaken($0)
        }
        var doc = LiquidDoc(format: LiquidDoc.knownFormat,
                            id: id,
                            title: parsed.title,
                            author: authorName,
                            created: created,
                            body: parsed.body,
                            links: [],
                            wraps: nil,
                            fileURL: folderURL.appendingPathComponent(id)
                                .appendingPathExtension(LiquidDoc.fileExtension))
        doc.documentType = LiquidDoc.DocumentType.transcript.rawValue
        doc.date = parsed.date
        guard (try? doc.jsonData().write(to: doc.fileURL, options: .atomic)) != nil else {
            showNote("Could not write “\(parsed.title)”.")
            return nil
        }
        ensureSpeakersKnown(parsed.speakers)
        return doc
    }

    /// Every speaker a person the system knows: a name People does not
    /// answer to (by display name or alias) starts a contact record,
    /// completable later in the person's form.
    func ensureSpeakersKnown(_ speakers: [String]) {
        for name in speakers where people.person(named: name) == nil {
            people.upsert(Person(displayName: name))
        }
    }

    /// One statement copied into a note of its own: the speaker's words
    /// become the body, a span-scoped citation links back to the
    /// statement in the transcript, and `onBehalfOf` records whose
    /// words they are. The Digital Letters lift, landing as a note in
    /// the community folder.
    func liftStatement(_ paragraph: LiquidDoc.Paragraph, from transcript: LiquidDoc) {
        guard let speaker = paragraph.speaker else { return }
        guard let folderURL = index.folderURL else {
            showNote("Choose a library folder first.")
            return
        }
        let statement = paragraph.displayText
        let created = Date.now
        let id = LiquidAddress.makeID(author: authorName, created: created) {
            self.index.isIDTaken($0)
        }
        let isOwnWords = speaker.caseInsensitiveCompare(authorName) == .orderedSame
        let body = [
            LiquidDoc.Paragraph(id: "p1", heading: nil, text: statement),
            LiquidDoc.Paragraph(id: "p2", heading: nil,
                text: "Spoken by \(speaker) in “\(transcript.title)”, \(transcript.listedDateText) [\(transcript.id)#\(paragraph.id)]"),
        ]
        var doc = LiquidDoc(format: LiquidDoc.knownFormat,
                            id: id,
                            title: "\(speaker) — \(transcript.title)",
                            author: authorName,
                            created: created,
                            body: body,
                            // The way back: a span-scoped citation to the
                            // statement it was lifted from.
                            links: [LiquidDoc.Link(to: transcript.id,
                                                   fragment: paragraph.id,
                                                   rel: DocumentRelation.cites.rawValue,
                                                   span: statement)],
                            wraps: nil,
                            fileURL: folderURL.appendingPathComponent(id)
                                .appendingPathExtension(LiquidDoc.fileExtension))
        doc.documentType = LiquidDoc.DocumentType.extract.rawValue
        doc.date = transcript.date
        if !isOwnWords { doc.onBehalfOf = speaker }
        guard (try? doc.jsonData().write(to: doc.fileURL, options: .atomic)) != nil else {
            showNote("Could not write the note.")
            return
        }
        index.rescan()
        selectedDocID = id
        showNote("Copied \(speaker)’s statement into a new note, linked to the transcript.")
    }

    /// Everything one speaker said, copied into a single note: each
    /// statement its own paragraph wearing the transcript's address at
    /// its foot — [transcript#paragraph], a live link — plus a citation
    /// link per statement, so a reader follows any section to its
    /// source.
    func liftAllStatements(of speaker: String, from transcript: LiquidDoc) {
        let statements = (transcript.body ?? []).filter {
            $0.speaker?.caseInsensitiveCompare(speaker) == .orderedSame
        }
        guard !statements.isEmpty else { return }
        guard let folderURL = index.folderURL else {
            showNote("Choose a library folder first.")
            return
        }
        let created = Date.now
        let id = LiquidAddress.makeID(author: authorName, created: created) {
            self.index.isIDTaken($0)
        }
        var body: [LiquidDoc.Paragraph] = [
            LiquidDoc.Paragraph(id: "p1", heading: nil,
                text: "Everything \(speaker) said in “\(transcript.title)”, \(transcript.listedDateText) [\(transcript.id)]"),
        ]
        var links: [LiquidDoc.Link] = [
            LiquidDoc.Link(to: transcript.id, fragment: nil,
                           rel: DocumentRelation.cites.rawValue),
        ]
        for (offset, statement) in statements.enumerated() {
            let words = statement.displayText
            body.append(LiquidDoc.Paragraph(
                id: "p\(offset + 2)", heading: nil,
                text: words + " [\(transcript.id)#\(statement.id)]"))
            links.append(LiquidDoc.Link(to: transcript.id,
                                        fragment: statement.id,
                                        rel: DocumentRelation.cites.rawValue,
                                        span: words))
        }
        let isOwnWords = speaker.caseInsensitiveCompare(authorName) == .orderedSame
        var doc = LiquidDoc(format: LiquidDoc.knownFormat,
                            id: id,
                            title: "\(speaker) in “\(transcript.title)”",
                            author: authorName,
                            created: created,
                            body: body,
                            links: links,
                            wraps: nil,
                            fileURL: folderURL.appendingPathComponent(id)
                                .appendingPathExtension(LiquidDoc.fileExtension))
        doc.documentType = LiquidDoc.DocumentType.extract.rawValue
        doc.date = transcript.date
        if !isOwnWords { doc.onBehalfOf = speaker }
        guard (try? doc.jsonData().write(to: doc.fileURL, options: .atomic)) != nil else {
            showNote("Could not write the note.")
            return
        }
        index.rescan()
        selectedDocID = id
        showNote("Copied all \(statements.count) of \(speaker)’s statements into a new note, each linked to its place in the transcript.")
    }
}
