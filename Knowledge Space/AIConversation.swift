import Foundation
#if os(macOS)
import AppKit
#endif

// An AI conversation, captured from the web and landing the transcript
// way: the exchange as one document whose every turn is addressable and
// ascribable — the human to a person the system knows, the model to an
// agent whose identity (vendor, model, version) rides behind its name.
// Where a meeting transcript's other party is a person, here it is a
// model, so each generated turn carries its provenance ("generated",
// "unverified", and the human turn that elicited it) — and that
// provenance travels into any note a statement is later lifted into, so
// "where did this claim come from" stays answerable after the words move.

/// Parses the Safari extension's capture JSON — a conversation extracted
/// from claude.ai, chatgpt.com, or Gemini — into the flat, speaker-per-turn
/// shape the reader already renders for transcripts, plus the provenance
/// and model identity an AI exchange needs. The capture schema is the
/// extension's contract; the parsing turns it into `LiquidDoc` parts an
/// `AppState` can adopt.
nonisolated enum AIConversationImporter {

    struct Result {
        let title: String
        /// The conversation's day, for listing and sorting.
        let date: LiquidDate?
        /// The people who spoke — the human side — to be made known to the
        /// system. Models are never in here; they are `agents`.
        let personSpeakers: [String]
        /// The models that spoke, one per distinct model seen.
        let agents: [LiquidDoc.Agent]
        /// Where this came from and how, recorded honestly.
        let aiSource: LiquidDoc.AISource
        let body: [LiquidDoc.Paragraph]
        /// The vendor's own conversation id, for detecting a re-import of
        /// the same thread.
        let conversationID: String?
    }

    // MARK: The capture schema (the extension's contract)

    private struct Capture: Decodable {
        var title: String?
        var capturedAt: String?
        var conversationCompletedAt: String?
        var timeConfidence: String?
        var fidelity: String?
        var source: Source?
        var speakers: [Speaker]?
        var body: [Turn]?

        struct Source: Decodable {
            var surface: String?
            var sourceURL: String?
            var conversationID: String?
            var captureMethod: String?
            var extractorVersion: String?
        }

        struct Speaker: Decodable {
            var id: String?
            var name: String?
            var kind: String?          // "person" | "agent"
            var vendor: String?
            var modelFamily: String?
            var modelVersion: String?
            var modelRaw: String?
            var modelConfidence: String?
        }

        struct Turn: Decodable {
            var id: String?
            var speaker: String?       // a Speaker.id
            var heading: Int?
            var provenance: String?    // "human" | "generated"
            var verification: String?
            var elicitedBy: String?    // a Turn.id
            var paragraphs: [Para]?

            struct Para: Decodable {
                var id: String?
                var text: String?
            }
        }
    }

    /// Whether data reads as a captured AI conversation: it decodes, names
    /// at least one agent speaker, and has at least one turn. The extension
    /// declares the type in the file name (`.aiconv.json`); this is the
    /// belt-and-braces content check the ingest uses before parsing.
    static func looksLikeCapture(_ data: Data) -> Bool {
        guard let capture = try? JSONDecoder().decode(Capture.self, from: data) else {
            return false
        }
        let hasAgent = (capture.speakers ?? []).contains { $0.kind == "agent" }
        let hasTurns = !(capture.body ?? []).isEmpty
        return hasAgent && hasTurns
    }

    /// Parses capture JSON into `Result`, substituting `userName` for the
    /// human speaker (the extension stamps a placeholder; the app owns the
    /// name). Returns nil when the data is not a usable capture.
    static func importJSON(_ data: Data, userName: String) -> Result? {
        guard let capture = try? JSONDecoder().decode(Capture.self, from: data),
              let turns = capture.body, !turns.isEmpty else { return nil }

        // Speaker id → resolved name and kind. A person's name becomes the
        // app's own user name; an agent keeps its model name.
        var speakerName: [String: String] = [:]
        var speakerIsAgent: [String: Bool] = [:]
        var agents: [LiquidDoc.Agent] = []
        var personSpeakers: [String] = []
        for speaker in capture.speakers ?? [] {
            guard let id = speaker.id else { continue }
            let isAgent = speaker.kind == "agent"
            speakerIsAgent[id] = isAgent
            if isAgent {
                let name = (speaker.name?.trimmingCharacters(in: .whitespaces)).flatMap {
                    $0.isEmpty ? nil : $0
                } ?? "\(speaker.vendor ?? "AI") assistant"
                speakerName[id] = name
                if !agents.contains(where: { $0.name == name }) {
                    agents.append(LiquidDoc.Agent(
                        name: name, vendor: speaker.vendor,
                        modelFamily: speaker.modelFamily,
                        modelVersion: speaker.modelVersion,
                        modelRaw: speaker.modelRaw,
                        modelConfidence: speaker.modelConfidence ?? "unknown"))
                }
            } else {
                speakerName[id] = userName
                if !personSpeakers.contains(userName) { personSpeakers.append(userName) }
            }
        }

        // Turn id → the id of its first paragraph, so `elicitedBy` (which
        // names a turn) can point at an addressable paragraph.
        func paragraphID(turn: String, para: String) -> String { "\(turn).\(para)" }
        var firstParagraphOfTurn: [String: String] = [:]
        for turn in turns {
            guard let turnID = turn.id,
                  let firstPara = turn.paragraphs?.first?.id else { continue }
            firstParagraphOfTurn[turnID] = paragraphID(turn: turnID, para: firstPara)
        }

        var body: [LiquidDoc.Paragraph] = []
        var turnIndex = 0
        for turn in turns {
            let turnID = turn.id ?? "t\(turnIndex + 1)"
            turnIndex += 1
            let paras = turn.paragraphs ?? []
            guard !paras.isEmpty else { continue }
            let speakerID = turn.speaker ?? ""
            let name = speakerName[speakerID]
            let isGenerated = turn.provenance == "generated"
                || (speakerIsAgent[speakerID] ?? false)
            let provenance = turn.provenance ?? (isGenerated ? "generated" : "human")
            let verification = turn.verification
                ?? (isGenerated ? "unverified" : nil)
            let elicitedByParagraph = turn.elicitedBy.flatMap { firstParagraphOfTurn[$0] }

            for (offset, para) in paras.enumerated() {
                let paraID = para.id ?? "p\(offset + 1)"
                let id = paragraphID(turn: turnID, para: paraID)
                var text = (para.text ?? "").trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                // The name leads the first paragraph of a turn so a
                // plain-text reader keeps attribution; continuation
                // paragraphs of the same turn stay clean, and the reader
                // shows the name once per turn.
                if offset == 0, let name { text = "\(name): \(text)" }
                body.append(LiquidDoc.Paragraph(
                    id: id,
                    heading: offset == 0 ? turn.heading.map { min(max($0, 1), 3) } : nil,
                    text: text,
                    speaker: name,
                    provenance: provenance,
                    verification: verification,
                    // The eliciting turn is recorded on the turn's first
                    // paragraph; the rest of the turn shares its cause.
                    elicitedBy: elicitedByParagraph))
            }
        }
        guard !body.isEmpty else { return nil }

        let source = capture.source
        let capturedAt = capture.capturedAt.flatMap(LiquidDoc.parseISO8601) ?? Date.now
        let completedAt = capture.conversationCompletedAt.flatMap(LiquidDoc.parseISO8601)
            ?? capturedAt
        let aiSource = LiquidDoc.AISource(
            surface: source?.surface,
            sourceURL: source?.sourceURL,
            conversationID: source?.conversationID,
            captureMethod: source?.captureMethod ?? "domExtraction",
            extractorVersion: source?.extractorVersion,
            capturedAt: capturedAt,
            timeConfidence: capture.timeConfidence ?? "captureTime",
            fidelity: capture.fidelity ?? "verbatim")

        let title = (capture.title?.trimmingCharacters(in: .whitespaces)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? Self.fallbackTitle(surface: source?.surface, date: completedAt)

        return Result(title: title,
                      date: Self.day(completedAt),
                      personSpeakers: personSpeakers,
                      agents: agents,
                      aiSource: aiSource,
                      body: body,
                      conversationID: source?.conversationID)
    }

    /// The conversation's calendar day, in UTC, as the document's human date.
    private static func day(_ date: Date) -> LiquidDate {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return LiquidDate(isoString: formatter.string(from: date)) ?? LiquidDate(isoString: "2026-01-01")!
    }

    /// A title for a capture that arrived without one: the surface and the
    /// day, so an untitled thread is still recognisable in a list.
    private static func fallbackTitle(surface: String?, date: Date) -> String {
        let where_ = (surface?.trimmingCharacters(in: .whitespaces)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? "AI"
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return "Conversation on \(where_), \(formatter.string(from: date))"
    }
}
