import Foundation
import FoundationModels

/// AI analysis of a note, written into the note itself as Visual-Meta:
/// each analysis is one paragraph carrying a delimited machine-readable
/// block, in the appendix spirit — metadata on the same level as the
/// content, never in a separate data layer that can be lost. A block is
/// removed as cleanly as it was added: drop its paragraph and rewrite
/// the file. The blocks are single-line so they survive a round trip
/// through any editor that re-parses the body line by line.
///
/// The parsed values are exposed on LiquidDoc (`sentimentValue`,
/// `topicKeywords`), so any view — K-Nav, the Weave, a future bot —
/// can weave sentiment against keywords across the library.
nonisolated enum NoteAnalysis {

    static let generator = "Knowledge Space 1.0"

    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case sentiment
        case topics

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .sentiment: "Sentiment"
            case .topics: "Topic"
            }
        }

        /// The block's Visual-Meta wrapper markers.
        var startMarker: String { "@{knowledge-space-\(rawValue)-start}" }
        var endMarker: String { "@{knowledge-space-\(rawValue)-end}" }
        /// The paragraph id the block is written under (informative; the
        /// marker, not the id, is what parsing anchors on).
        var paragraphID: String { "ks-\(rawValue)" }
    }

    // MARK: - The generated analyses

    @Generable
    struct GeneratedSentiment {
        @Guide(description: "The note's overall sentiment: exactly one of positive, negative, mixed, neutral")
        var value: String
        @Guide(description: "One short sentence explaining the reading, grounded in the note's own words")
        var note: String
    }

    @Generable
    struct GeneratedTopics {
        @Guide(description: "Three to six short topic keywords or phrases naming what the note is about, most central first")
        var topics: [String]
    }

    /// Runs the analysis on-device and returns a copy of the document
    /// with the result written in as a Visual-Meta block. No text leaves
    /// the machine.
    @concurrent
    static func run(_ kind: Kind, on doc: LiquidDoc) async throws -> LiquidDoc {
        let text = contentText(of: doc)
        let session = LanguageModelSession()
        let fields: [(String, String)]
        switch kind {
        case .sentiment:
            let response = try await session.respond(
                to: "Read this note and judge its overall sentiment.\n\n\(text)",
                generating: GeneratedSentiment.self)
            let value = ["positive", "negative", "mixed", "neutral"]
                .first { $0 == response.content.value.lowercased()
                    .trimmingCharacters(in: .whitespaces) } ?? "neutral"
            fields = [("value", value), ("note", response.content.note)]
        case .topics:
            let response = try await session.respond(
                to: "Read this note and name its topics.\n\n\(text)",
                generating: GeneratedTopics.self)
            let topics = response.content.topics
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            fields = [("topics", topics.joined(separator: ", "))]
        }
        return appending(kind, fields: fields, to: removing(kind, from: doc))
    }

    /// The note's words alone: body paragraphs minus any Visual-Meta
    /// appendix and any earlier analysis blocks.
    private static func contentText(of doc: LiquidDoc) -> String {
        let appendixIDs = doc.visualMetaParagraphIDs
        return (doc.body ?? [])
            .filter { !appendixIDs.contains($0.id) && !isAnalysisParagraph($0) }
            .map(\.displayText)
            .joined(separator: "\n\n")
    }

    // MARK: - Reading and writing the blocks

    static func isAnalysisParagraph(_ paragraph: LiquidDoc.Paragraph) -> Bool {
        paragraph.text.contains("@{knowledge-space-")
    }

    static func block(_ kind: Kind, in doc: LiquidDoc) -> String? {
        (doc.body ?? []).first { $0.text.contains(kind.startMarker) }?.text
    }

    static func field(_ name: String, ofBlock block: String) -> String? {
        let pattern = "\(name)\\s*=\\s*\\{([^}]*)\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)),
              let range = Range(match.range(at: 1), in: block) else { return nil }
        let value = String(block[range]).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// A copy of the document with the analysis block removed — what
    /// un-clicking the analysis button writes back.
    static func removing(_ kind: Kind, from doc: LiquidDoc) -> LiquidDoc {
        guard let body = doc.body else { return doc }
        let kept = body.filter { !$0.text.contains(kind.startMarker) }
        guard kept.count != body.count else { return doc }
        return replacingBody(of: doc, with: kept)
    }

    private static func appending(_ kind: Kind, fields: [(String, String)],
                                  to doc: LiquidDoc) -> LiquidDoc {
        guard let body = doc.body else { return doc }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var allFields = fields
        allFields.append(("analyzed", formatter.string(from: .now)))
        allFields.append(("generator", generator))
        let record = allFields
            .map { "\($0.0) = {\(VisualMeta.bibtexEscaped($0.1))}" }
            .joined(separator: ", ")
        // One line, so any line-based body editor keeps the block whole.
        let text = "\(kind.startMarker) @\(kind.rawValue){ \(record), } \(kind.endMarker)"
        var paragraphs = body
        paragraphs.append(LiquidDoc.Paragraph(id: uniqueID(kind.paragraphID, among: body),
                                              heading: nil, text: text))
        return replacingBody(of: doc, with: paragraphs)
    }

    private static func uniqueID(_ preferred: String, among body: [LiquidDoc.Paragraph]) -> String {
        var id = preferred
        var counter = 1
        while body.contains(where: { $0.id == id }) {
            counter += 1
            id = "\(preferred)-\(counter)"
        }
        return id
    }

    private static func replacingBody(of doc: LiquidDoc,
                                      with paragraphs: [LiquidDoc.Paragraph]) -> LiquidDoc {
        // Only the body changes; every other field rides along untouched.
        var updated = doc
        updated.body = paragraphs
        return updated
    }
}

// The analysis values as any view reads them.
extension LiquidDoc {

    nonisolated func hasAnalysis(_ kind: NoteAnalysis.Kind) -> Bool {
        NoteAnalysis.block(kind, in: self) != nil
    }

    /// "positive", "negative", "mixed", or "neutral" — nil when no
    /// sentiment analysis has been run.
    nonisolated var sentimentValue: String? {
        NoteAnalysis.block(.sentiment, in: self)
            .flatMap { NoteAnalysis.field("value", ofBlock: $0) }
    }

    /// The one-sentence reading behind the sentiment.
    nonisolated var sentimentNote: String? {
        NoteAnalysis.block(.sentiment, in: self)
            .flatMap { NoteAnalysis.field("note", ofBlock: $0) }
    }

    /// The note's topic keywords — empty when no topic analysis has run.
    nonisolated var topicKeywords: [String] {
        guard let block = NoteAnalysis.block(.topics, in: self),
              let joined = NoteAnalysis.field("topics", ofBlock: block) else { return [] }
        return joined.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Ids of analysis-block paragraphs, so the reader can render them
    /// unobtrusively, like the Visual-Meta appendix.
    nonisolated var analysisParagraphIDs: Set<String> {
        Set((body ?? []).filter(NoteAnalysis.isAnalysisParagraph).map(\.id))
    }
}
