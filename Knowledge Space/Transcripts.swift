import Foundation
import FoundationModels
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
        let statement = withoutLeadingTimecode(
            String(match.statement).trimmingCharacters(in: .whitespaces))
        return (name, statement)
    }

    /// A statement with any leading timecode dropped — Sonix puts it
    /// after the colon ("Frode Hegland: [00:01:02] …"), the mirror of
    /// the Zoom forms the speaker pattern drops around the name. Both
    /// the plain and the markdown paths pass through here, so timecodes
    /// read the same whichever shape the transcript arrived in.
    private static func withoutLeadingTimecode(_ statement: String) -> String {
        var statement = statement
        if let timecode = statement.firstMatch(
            of: /^(?:\[[0-9:.\-–— ]+\]|\([0-9:.\-–— ]+\)|[0-9]{1,2}:[0-9]{2}:[0-9]{2})\s+/) {
            statement.removeSubrange(timecode.range)
        }
        return statement
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

    // MARK: Markdown conversations (AI chat exports)

    /// The bold marker a markdown conversation export opens turns with —
    /// "**Frode:** …" or "**Claude**: …" (the colon inside or outside the
    /// bold). The colon is required: a bold lead like "**effort
    /// heuristic** — …" is emphasis, not attribution.
    private static let markdownTurnPattern =
        /^\*\*(?<name>[^*:]{1,40})(?::\*\*|\*\*:)\s*(?<statement>.*)$/

    private static func markdownTurnMatch(in line: String) -> (name: String, statement: String)? {
        guard let match = line.wholeMatch(of: markdownTurnPattern) else { return nil }
        let name = String(match.name).trimmingCharacters(in: .whitespaces)
        // The name must read as a name — the same shape a plain
        // transcript's speaker line requires.
        guard speakerMatch(in: "\(name): x") != nil else { return nil }
        return (name, withoutLeadingTimecode(
            String(match.statement).trimmingCharacters(in: .whitespaces)))
    }

    /// Whether text reads as a markdown conversation export: bold-marked
    /// turns taken by at least two speakers.
    static func looksLikeMarkdownConversation(_ text: String) -> Bool {
        markdownSpeakers(in: text).count >= 2
    }

    /// The names that open turns, kept honest by recurrence: a stray
    /// "**Note:** …" inside an answer must not become a speaker. Two
    /// distinct names pass as they stand (a single exchange); beyond
    /// that a name must open at least two turns.
    private static func markdownSpeakers(in text: String) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let (name, _) = markdownTurnMatch(in: line) else { continue }
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        if order.count == 2 { return order }
        return order.filter { counts[$0, default: 0] >= 2 }
    }

    /// Imports a markdown conversation export — a Claude, ChatGPT, or
    /// Gemini transcript saved as markdown, or any conversation written
    /// in that shape. Title from the leading "# " heading, the day from
    /// a byline like "*A conversation with Claude — 17 August 2026*",
    /// "---" rules dropped as turn separators, and each turn's paragraphs
    /// carrying its speaker — the name leading the first (plain-text
    /// readers lose nothing), continuations clean, exactly as the live
    /// capture lands them.
    static func importMarkdown(_ text: String, fallbackTitle: String,
                               speakers precomputed: [String]? = nil) -> Result {
        let speakers = precomputed ?? markdownSpeakers(in: text)
        var title: String?
        var date: LiquidDate?
        var body: [LiquidDoc.Paragraph] = []
        var currentSpeaker: String?

        func append(_ text: String, speaker: String?, opensTurn: Bool) {
            let prefixed = opensTurn ? speaker.map { "\($0): \(text)" } ?? text : text
            body.append(LiquidDoc.Paragraph(id: "p\(body.count + 1)", heading: nil,
                                            text: prefixed, speaker: speaker))
        }

        for block in markdownBlocks(of: text) {
            if block.count >= 3, block.allSatisfy({ $0 == "-" }) { continue }  // a rule between turns
            if let (name, statement) = markdownTurnMatch(in: block),
               speakers.contains(name) {
                currentSpeaker = name
                if !statement.isEmpty { append(statement, speaker: name, opensTurn: true) }
            } else if let currentSpeaker {
                append(block, speaker: currentSpeaker, opensTurn: false)
            } else if title == nil, block.hasPrefix("# ") {
                title = String(block.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else {
                // The preamble: a dated byline sets the day; a pure
                // byline ("A conversation with …") is metadata, already
                // carried by title and date — anything more stays words.
                let stripped = block.trimmingCharacters(in: CharacterSet(charactersIn: "*_ "))
                if date == nil, let tail = stripped.split(separator: "—").last,
                   let opening = parseDate(String(tail)) {
                    date = opening
                    if stripped.lowercased().hasPrefix("a conversation") { continue }
                }
                append(block, speaker: nil, opensTurn: false)
            }
        }
        return Result(title: title ?? fallbackTitle,
                      date: date ?? parseDate(fallbackTitle),
                      speakers: speakers,
                      body: body)
    }

    /// Markdown paragraphs: blocks separated by blank lines, wrapped
    /// lines within a block rejoined. A heading is a block of its own
    /// even without a blank line after it — "# Title" directly above a
    /// byline must not swallow it.
    private static func markdownBlocks(of text: String) -> [String] {
        var blocks: [String] = []
        var current: [String] = []
        func flush() {
            if !current.isEmpty {
                blocks.append(current.joined(separator: " "))
                current = []
            }
        }
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("#") {
                flush()
                blocks.append(line)
            } else {
                current.append(line)
            }
        }
        flush()
        return blocks
    }

    /// The one door every transcript enters through, whoever spoke: a
    /// markdown conversation export parses as its turns, anything else
    /// as a plain "Name: statement" transcript.
    static func importAuto(_ text: String, fallbackTitle: String) -> Result {
        // One scan decides and feeds the import — the speaker sweep is
        // the costly part, so it is not run twice.
        let speakers = markdownSpeakers(in: text)
        return speakers.count >= 2
            ? importMarkdown(text, fallbackTitle: fallbackTitle, speakers: speakers)
            : importText(text, fallbackTitle: fallbackTitle)
    }

    // MARK: Titling

    /// The words a transcript's filename offers beyond its date —
    /// "Future Text Lab 6 July 2026" offers "Future Text Lab"; a
    /// filename that is only the date offers nothing.
    static func filenameDescriptor(_ name: String) -> String {
        var words = name.split(whereSeparator: { $0 == " " || $0 == "_" }).map(String.init)
        // A date rides at either end, two to four words long ("6 July 26",
        // "July 6, 2026"); pull it off and keep the words that remain.
        outer: for length in stride(from: min(4, words.count), through: 2, by: -1) {
            if parseDate(words.prefix(length).joined(separator: " ")) != nil {
                words.removeFirst(length); break outer
            }
            if parseDate(words.suffix(length).joined(separator: " ")) != nil {
                words.removeLast(length); break outer
            }
        }
        words.removeAll { parseDate($0) != nil }   // "2026-07-06" is one word
        return words.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–—_,"))
    }

    /// One short line saying what a conversation was about, read from
    /// its opening statements by the on-device model — nothing leaves
    /// the machine. Guardrails are the permissive transformation kind:
    /// summarizing someone else's words is Apple's own example of it,
    /// and the default kind refuses ordinary meeting chatter as
    /// "sensitive". Permissive mode only holds for plain String
    /// generation, so the line is asked for and tidied as prose rather
    /// than through a @Generable type. Nil when the model is
    /// unavailable or still declines.
    @concurrent
    static func summaryLine(for text: String) async -> String? {
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        guard model.isAvailable else { return nil }
        let session = LanguageModelSession(model: model)
        let response = try? await session.respond(
            to: "Summarize what this conversation is about in one short sentence of at most twelve words. Reply with the sentence alone — no quotation marks.\n\n\(text)")
        guard var line = response?.content
            .split(whereSeparator: \.isNewline).first
            .map(String.init) else { return nil }
        line = line.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".“”\""))
        // A refusal or a ramble is not a title.
        guard !line.isEmpty, line.count <= 120,
              !line.localizedCaseInsensitiveContains("sorry"),
              !line.localizedCaseInsensitiveContains("cannot") else { return nil }
        return line
    }

    // MARK: Models among the speakers

    /// The vendor behind a speaker name that is a model, nil for a
    /// person — the line between People and a document's `agents`.
    /// Matches the name's first word, so "Claude", "Claude 3.7 Sonnet",
    /// and "ChatGPT (GPT-5)" are all models.
    static func agentVendor(for name: String) -> String? {
        guard let first = name.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "-") })
            .first.map(String.init) else { return nil }
        if first == "chatgpt" || first.hasPrefix("gpt") { return "OpenAI" }
        var vendors: [String: String] = [:]
        vendors["claude"] = "Anthropic"
        vendors["gemini"] = "Google"
        vendors["copilot"] = "Microsoft"
        vendors["grok"] = "xAI"
        vendors["llama"] = "Meta"
        vendors["mistral"] = "Mistral AI"
        vendors["deepseek"] = "DeepSeek"
        vendors["qwen"] = "Alibaba"
        return vendors[first]
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
        var types: [UTType] = [.plainText, .rtf, .text]
        if let markdown = UTType(filenameExtension: "md") { types.append(markdown) }
        panel.allowedContentTypes = types
        panel.message = "Choose transcripts — meetings or AI conversations; plain text, markdown, or RTF, speaker names before statements (“Mark Anderson: …” or “**Claude:** …”)."
        panel.prompt = "Import"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        var imported: [String] = []
        for url in panel.urls {
            guard let text = Self.readTranscriptText(at: url) else { continue }
            let parsed = TranscriptImporter.importAuto(
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
    /// known to the system. Models among the speakers make it an AI
    /// conversation: they become the document's `agents` (never People),
    /// and every turn carries its provenance — "human" or "generated",
    /// a generated turn pointing at the human turn that elicited it —
    /// so a statement lifted later stays honest about where its words
    /// began. Human and AI transcripts thereby enter through one door.
    private func adoptTranscript(_ parsed: TranscriptImporter.Result) -> LiquidDoc? {
        guard let folderURL = index.folderURL else { return nil }
        let agents = parsed.speakers.compactMap { name in
            TranscriptImporter.agentVendor(for: name).map {
                LiquidDoc.Agent(name: name, vendor: $0, modelConfidence: "unknown")
            }
        }
        let agentNames = Set(agents.map { $0.name.lowercased() })
        let personSpeakers = parsed.speakers.filter { !agentNames.contains($0.lowercased()) }

        var body = parsed.body
        if !agents.isEmpty {
            var lastHumanTurnStart: String?
            var previousSpeaker: String?
            body = body.map { paragraph in
                var paragraph = paragraph
                if let speaker = paragraph.speaker {
                    if agentNames.contains(speaker.lowercased()) {
                        paragraph.provenance = "generated"
                        paragraph.verification = "unverified"
                        paragraph.elicitedBy = lastHumanTurnStart
                    } else {
                        paragraph.provenance = "human"
                        if speaker != previousSpeaker { lastHumanTurnStart = paragraph.id }
                    }
                }
                // A plain paragraph (preamble, a rule) does not break a
                // speaker's run.
                if paragraph.speaker != nil { previousSpeaker = paragraph.speaker }
                return paragraph
            }
        }

        let created = Date.now

        // The listed title, by who spoke. An AI conversation keeps its
        // own title behind an "AI" prefix. A human meeting is titled by
        // its day plus whatever describes it — the filename's words when
        // they say more than the date, else a one-sentence summary the
        // on-device model fills in after the write.
        let title: String
        var dateOnlyTitle = false
        if agents.isEmpty {
            let dateText = parsed.date?.displayText
                ?? created.formatted(date: .long, time: .omitted)
            let descriptor = TranscriptImporter.filenameDescriptor(parsed.title)
            dateOnlyTitle = descriptor.isEmpty
            title = dateOnlyTitle ? dateText : "\(dateText) — \(descriptor)"
        } else {
            title = parsed.title.hasPrefix("AI:") ? parsed.title : "AI: \(parsed.title)"
        }

        let id = LiquidAddress.makeID(author: authorName, created: created) {
            self.index.isIDTaken($0)
        }
        var doc = LiquidDoc(format: LiquidDoc.knownFormat,
                            id: id,
                            title: title,
                            author: authorName,
                            created: created,
                            body: body,
                            links: [],
                            wraps: nil,
                            fileURL: folderURL.appendingPathComponent(id)
                                .appendingPathExtension(LiquidDoc.fileExtension))
        doc.documentType = agents.isEmpty
            ? LiquidDoc.DocumentType.transcript.rawValue
            : LiquidDoc.DocumentType.aiConversation.rawValue
        doc.date = parsed.date
        if !agents.isEmpty {
            doc.agents = agents
            // Recorded honestly: read from a file the user chose, at the
            // import moment — not captured live from the page.
            doc.aiSource = LiquidDoc.AISource(captureMethod: "fileImport",
                                              capturedAt: created,
                                              timeConfidence: "captureTime",
                                              fidelity: "asExported")
        }
        guard (try? doc.jsonData().write(to: doc.fileURL, options: .atomic)) != nil else {
            showNote("Could not write “\(parsed.title)”.")
            return nil
        }
        ensureSpeakersKnown(personSpeakers)
        if dateOnlyTitle { retitleTranscriptFromSummary(doc) }
        return doc
    }

    /// Fills in the sentence a date-only meeting title is missing: the
    /// on-device model reads the transcript's opening and says in one
    /// line what it was about, and the title becomes
    /// "6 July 2026 — <that line>". Best-effort and after the fact —
    /// the transcript is already written and listed under its day, and
    /// if the model is unavailable the date-only title simply stands.
    /// The new title merges onto the file's current bytes.
    private func retitleTranscriptFromSummary(_ doc: LiquidDoc) {
        let dateText = doc.title
        var opening = ""
        for paragraph in doc.body ?? [] {
            opening += paragraph.text + "\n"
            if opening.count > 5000 { break }
        }
        guard !opening.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let text = opening
        Task {
            guard let summary = await TranscriptImporter.summaryLine(for: text) else { return }
            mutateNoteFile(doc) { $0.title = "\(dateText) — \(summary)" }
        }
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
        // A model generates; a person speaks — the attribution line says
        // which, so the lifted note is honest about where its words began.
        let verb = transcript.isAgentSpeaker(speaker) ? "Generated by" : "Spoken by"
        let body = [
            LiquidDoc.Paragraph(id: "p1", heading: nil, text: statement),
            LiquidDoc.Paragraph(id: "p2", heading: nil,
                text: "\(verb) \(speaker) in “\(transcript.title)”, \(transcript.listedDateText) [\(transcript.id)#\(paragraph.id)]"),
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
                text: words + " [\(transcript.id)#\(statement.id)]",
                provenance: statement.provenance,
                verification: statement.verification,
                elicitedBy: statement.elicitedBy))
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
        // The conversation's source and the model behind these words travel
        // with the note; each paragraph already carries its own provenance.
        if transcript.isAIConversation || body.contains(where: { $0.provenance != nil }) {
            doc.aiSource = transcript.aiSource
            if let agent = transcript.agent(named: speaker) { doc.agents = [agent] }
        }
        guard (try? doc.jsonData().write(to: doc.fileURL, options: .atomic)) != nil else {
            showNote("Could not write the note.")
            return
        }
        index.rescan()
        selectedDocID = id
        showNote("Copied all \(statements.count) of \(speaker)’s statements into a new note, each linked to its place in the transcript.")
    }
}
