#if os(macOS)
import SwiftUI
import AVFoundation
import Speech
import FoundationModels

/// The session recorder: press Record at the foot of a session note and
/// the Mac listens — SpeechAnalyzer transcribes on this machine as the
/// room talks, with no ceiling on length. The transcript is distilled
/// on-device into key sentences and keywords piece by piece *while
/// recording*, so Stop has only the last words left to read.
/// Nothing leaves the Mac: not the audio, not the words.
/// (macOS 27: the capture-to-analyzer pipeline, CaptureInputSequenceProvider,
/// arrived there; on 26 the session note simply has no Record line.)
@available(macOS 27, *)
@MainActor @Observable
final class SessionRecorder {

    enum Phase: Equatable {
        case idle
        case preparing    // permission, the language's model, the microphone
        case recording
        case distilling   // the transcript being read for its keys
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// When the recording began — the footer shows the running time.
    private(set) var startedAt: Date?
    /// The transcript as it stands: the finalized words, and the
    /// tentative tail still being refined — shown live, quietly, so the
    /// writer sees the machine is listening.
    private(set) var finalizedTranscript = ""
    private(set) var volatileTail = ""
    /// The keys found so far — distilled piece by piece while the room
    /// still talks, so Stop has only the tail left to read. The row
    /// shows the count climbing: the work is happening now, not later.
    private(set) var keySentencesSoFar: [String] = []
    private(set) var keywordsSoFar: [String] = []

    private var analyzer: SpeechAnalyzer?
    private var captureSession: AVCaptureSession?
    private var resultsTask: Task<Void, Never>?
    /// Finalized words not yet distilled, and the one piece in flight —
    /// pieces run one at a time, in spoken order.
    private var undistilled = ""
    private var distillTask: Task<Void, Never>?
    private var seenKeywords = Set<String>()
    /// The piece size: big enough to give the model whole thoughts,
    /// small enough that the tail left at Stop reads in one call.
    private static let pieceWordLimit = 800

    /// What a stopped recording hands back: the whole transcript, and
    /// the keys distilled from it. A failed distillation still returns
    /// the transcript — the words are never hostage to the analysis.
    struct Distillation: Sendable {
        var transcript: String
        var keySentences: [String]
        var keywords: [String]
    }

    func start() async {
        switch phase {
        case .idle, .failed: break
        default: return
        }
        phase = .preparing
        finalizedTranscript = ""
        volatileTail = ""
        undistilled = ""
        keySentencesSoFar = []
        keywordsSoFar = []
        seenKeywords = []

        guard await microphoneAllowed() else {
            phase = .failed("The microphone was not allowed — grant it in System Settings ▸ Privacy & Security ▸ Microphone.")
            return
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            phase = .failed("Transcription does not support this language yet.")
            return
        }
        do {
            // Progressive transcription: volatile hypotheses live, each
            // passage finalized as the model settles on it — made for
            // audio of any length, unlike the old one-minute dictation.
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            if let installation = try await AssetInventory
                .assetInstallationRequest(supporting: [transcriber]) {
                try await installation.downloadAndInstall()
            }
            guard let microphone = AVCaptureDevice.default(.microphone, for: .audio,
                                                           position: .unspecified) else {
                phase = .failed("No microphone could be found.")
                return
            }
            let provider = try await CaptureInputSequenceProvider
                .providerWithSession(from: microphone, compatibleWith: [transcriber])
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            try await analyzer.start(inputSequence: provider.analyzerInputs)

            resultsTask = Task {
                do {
                    for try await result in transcriber.results {
                        let words = String(result.text.characters)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if result.isFinal {
                            if !words.isEmpty {
                                finalizedTranscript = finalizedTranscript.isEmpty
                                    ? words : finalizedTranscript + " " + words
                                undistilled = undistilled.isEmpty
                                    ? words : undistilled + " " + words
                                distillMoreIfReady()
                            }
                            volatileTail = ""
                        } else {
                            volatileTail = words
                        }
                    }
                } catch {
                    // The stream ending after Stop is the normal course;
                    // only a death mid-recording is worth a word.
                    if phase == .recording {
                        phase = .failed("Transcription stopped: \(error.localizedDescription)")
                    }
                }
            }

            self.analyzer = analyzer
            self.captureSession = provider.captureSession
            // An audio-only capture session starts in a beat; started
            // here on the main actor rather than smuggling the
            // non-Sendable session across an executor.
            provider.captureSession.startRunning()
            startedAt = .now
            phase = .recording
        } catch {
            phase = .failed("Could not start recording: \(error.localizedDescription)")
        }
    }

    /// Whenever a whole piece of finalized words stands undistilled,
    /// send it to the model — while the room still talks. One piece in
    /// flight at a time, in spoken order; a finished piece looks for
    /// the next itself.
    private func distillMoreIfReady() {
        guard distillTask == nil, phase == .recording else { return }
        let words = undistilled.split(whereSeparator: \.isWhitespace)
        guard words.count >= Self.pieceWordLimit else { return }
        let piece = words.prefix(Self.pieceWordLimit).joined(separator: " ")
        undistilled = words.dropFirst(Self.pieceWordLimit).joined(separator: " ")
        distillTask = Task {
            await distillPiece(piece)
            distillTask = nil
            distillMoreIfReady()
        }
    }

    private func distillPiece(_ piece: String) async {
        do {
            merge(try await SessionDistiller.distill(transcript: piece))
        } catch {
            // The piece rejoins the queue's head, keeping the spoken
            // order — Stop (or the next piece's turn) retries it.
            undistilled = undistilled.isEmpty ? piece : piece + " " + undistilled
        }
    }

    private func merge(_ keys: SessionDistiller.Keys) {
        keySentencesSoFar += keys.keySentences
        for keyword in keys.keywords {
            guard seenKeywords.insert(keyword.lowercased()).inserted else { continue }
            keywordsSoFar.append(keyword)
        }
    }

    /// Stops listening, waits for the last words to finalize, distills
    /// what little remains — the bulk was distilled while recording —
    /// and hands back the whole. Nil when nothing was heard.
    func stopAndDistill() async -> Distillation? {
        guard phase == .recording else { return nil }
        phase = .distilling
        captureSession?.stopRunning()
        // Finalize what was heard, then finish. Not
        // finalizeAndFinishThroughEndOfInput(): that waits for the
        // input sequence to *terminate*, which a capture provider's
        // sequence only does when the capture pipeline is deallocated —
        // Stop would wait forever. finalize(through: nil) settles
        // everything consumed (the volatile tail arrives as final
        // results), and cancelAndFinishNow() ends the result stream.
        try? await analyzer?.finalize(through: nil)
        await analyzer?.cancelAndFinishNow()
        await resultsTask?.value
        // Let the piece in flight land, then read the tail: the words
        // still undistilled plus the never-finalized volatile end.
        await distillTask?.value
        distillTask = nil
        let transcript = currentTranscript()
        let volatile = volatileTail.trimmingCharacters(in: .whitespacesAndNewlines)
        var tail = undistilled
        if !volatile.isEmpty { tail = tail.isEmpty ? volatile : tail + " " + volatile }
        var tailFailure: String?
        if !tail.isEmpty {
            do {
                merge(try await SessionDistiller.distill(transcript: tail))
            } catch {
                tailFailure = error.localizedDescription
            }
        }
        let result = Distillation(transcript: transcript,
                                  keySentences: keySentencesSoFar,
                                  keywords: Array(keywordsSoFar.prefix(12)))
        release()
        guard !transcript.isEmpty else {
            phase = .failed("Nothing was heard.")
            return nil
        }
        phase = tailFailure.map { reason in
            // ModelManager failures are the machine's, not the words':
            // the on-device model's assets are missing or mid-download
            // (seen live: "UAF.FM.Overrides — no asset set"). Say where
            // to look instead of reciting an error code.
            let hint = reason.contains("ModelManager")
                ? " The Mac's on-device model looks unavailable — check System Settings ▸ Apple Intelligence & Siri (the model may still be downloading), or choose a server model in this app's Settings ▸ AI, then record again."
                : ""
            return .failed("The transcript was kept whole, but distilling failed: \(reason)\(hint)")
        } ?? .idle
        return result
    }

    /// The note is closing mid-recording: stop the microphone at once
    /// and hand back whatever was transcribed, undistilled — the caller
    /// writes it into the file so no words are lost to the closing.
    func abandon() -> String {
        let transcript = currentTranscript()
        captureSession?.stopRunning()
        resultsTask?.cancel()
        distillTask?.cancel()
        release()
        phase = .idle
        return transcript
    }

    private func currentTranscript() -> String {
        let tail = volatileTail.trimmingCharacters(in: .whitespacesAndNewlines)
        var transcript = finalizedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            transcript = transcript.isEmpty ? tail : transcript + " " + tail
        }
        return transcript
    }

    private func release() {
        captureSession = nil
        analyzer = nil
        resultsTask = nil
        distillTask = nil
        startedAt = nil
        finalizedTranscript = ""
        volatileTail = ""
        undistilled = ""
        keySentencesSoFar = []
        keywordsSoFar = []
        seenKeywords = []
    }

    private func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}

/// Distills a session's transcript on-device — FoundationModels, like
/// the note analyses — into the key sentences (verbatim, in spoken
/// order) and the keywords naming its subjects. A long session is read
/// in pieces the on-device model can hold, and the pieces' keys joined.
///
/// The model wears the permissive content-transformation guardrails:
/// a session's transcript is other people's words, which the default
/// guardrails refuse as "sensitive" — and summarizing someone else's
/// words is Apple's own example of the permissive kind. Permissive mode
/// only holds for plain String generation (Transcripts.summaryLine
/// learned both lessons first), so the keys are asked for as marked
/// plain text and parsed, never through a @Generable type.
nonisolated enum SessionDistiller {

    struct Keys: Sendable {
        var keySentences: [String]
        var keywords: [String]
    }

    @concurrent
    static func distill(transcript: String) async throws -> Keys {
        var sentences: [String] = []
        var keywords: [String] = []
        var seen = Set<String>()
        for piece in pieces(of: transcript, wordLimit: 1000) {
            let reply: String
            if await OrigamiLLM.shared.selectedEndpointModel() != nil {
                // The chosen server model (Settings ▸ AI) reads the
                // piece; a failed server falls back to Apple's inside
                // respond(), with the notice saying so.
                reply = try await OrigamiLLM.shared
                    .respond(instructions: nil, to: prompt(for: piece)).text
            } else {
                // Apple's model directly, wearing the permissive
                // guardrails a transcript needs — OrigamiLLM's own
                // Apple path wears the default kind, which refuses
                // meeting chatter.
                let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
                let session = LanguageModelSession(model: model)
                reply = try await session.respond(to: prompt(for: piece)).content
            }
            let parsed = parse(reply)
            sentences += parsed.keySentences
            for keyword in parsed.keywords {
                guard seen.insert(keyword.lowercased()).inserted else { continue }
                keywords.append(keyword)
            }
        }
        return Keys(keySentences: sentences, keywords: Array(keywords.prefix(12)))
    }

    private static func prompt(for piece: String) -> String {
        """
        This is the transcript — or part of one — of a session at a meeting or conference. \
        Pick out every key sentence — the sentences that carry the session's substance — \
        quoted verbatim in the order spoken, and four to ten short keywords naming what \
        it is about. Reply in exactly this form and nothing else:
        KEY SENTENCES:
        - first key sentence
        - next key sentence
        KEYWORDS: keyword, keyword, keyword

        \(piece)
        """
    }

    /// Reads the model's marked plain text back into keys — tolerant of
    /// bullets, numbering, blank lines, and a KEYWORDS line that never
    /// came.
    static func parse(_ reply: String) -> Keys {
        var sentences: [String] = []
        var keywords: [String] = []
        var inSentences = false
        for rawLine in reply.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let upper = line.uppercased()
            if upper.hasPrefix("KEY SENTENCES") { inSentences = true; continue }
            if upper.hasPrefix("KEYWORDS") {
                inSentences = false
                let list = line.dropFirst("KEYWORDS".count)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                keywords += list.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                continue
            }
            guard inSentences, !line.isEmpty else { continue }
            let sentence = stripBullet(line)
            if !sentence.isEmpty { sentences.append(sentence) }
        }
        return Keys(keySentences: sentences, keywords: keywords)
    }

    /// "- sentence", "• sentence", "3. sentence" → "sentence"; a line
    /// that merely begins with a number ("2026 will be…") keeps it.
    private static func stripBullet(_ line: String) -> String {
        if let match = line.wholeMatch(of: /^(?:[-•*]|\d{1,3}[.)])\s*(.*)$/) {
            return String(match.1).trimmingCharacters(in: .whitespaces)
        }
        return line
    }

    /// Whole-word pieces sized to the on-device model's window.
    private static func pieces(of text: String, wordLimit: Int) -> [String] {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count > wordLimit else { return [text] }
        return stride(from: 0, to: words.count, by: wordLimit).map {
            words[$0..<min($0 + wordLimit, words.count)].joined(separator: " ")
        }
    }
}

// MARK: - The recorder's line in the session's foot

/// One quiet line under the session's fields: Record, then the running
/// time with the last words heard, then — stopped — the distilling. The
/// result lands in the note as words: Key Sentences, Keywords, and the
/// Transcript whole, handed to the editor to append through its single
/// save path; the keywords also ride as the topics analysis block, so
/// K-Nav, the Weave, and every other view read them like any note's.
@available(macOS 27, *)
struct SessionRecorderRow: View {
    @Environment(AppState.self) private var state
    let doc: LiquidDoc
    /// Hands the distilled sections (leading "\n\n" included) back to
    /// the note's editor, which appends them to its buffer and saves.
    let appendSections: (String) -> Void

    @State private var recorder = SessionRecorder()

    var body: some View {
        row
            // The note closing mid-recording: the microphone stops and
            // the transcript so far is written straight into the file,
            // undistilled — closing a window must never cost the words.
            .onDisappear { flushOnClose() }
    }

    @ViewBuilder private var row: some View {
        switch recorder.phase {
        case .idle:
            recordButton
        case .preparing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Getting the microphone and the language model ready…")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        case .recording:
            HStack(spacing: 10) {
                Button {
                    Task { await stopRecording() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .help("Stop recording and distill the session's key sentences and keywords into this note")
                if let startedAt = recorder.startedAt {
                    Text(startedAt, style: .timer)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                // The distilling happens as the room talks — the count
                // climbing is the proof.
                if !recorder.keySentencesSoFar.isEmpty {
                    Text("\(recorder.keySentencesSoFar.count) key sentences")
                        .foregroundStyle(.secondary)
                }
                // Proof of listening: the newest words, trailing quietly.
                Text(liveTail)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 12))
        case .distilling:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                // The bulk was distilled while recording; only the last
                // words remain.
                Text("Distilling the last words…")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        case .failed(let reason):
            HStack(spacing: 10) {
                recordButton
                Text(reason)
                    .foregroundStyle(.orange)
            }
            .font(.system(size: 12))
        }
    }

    private var recordButton: some View {
        Button {
            Task { await recorder.start() }
        } label: {
            Label("Record Session", systemImage: "mic.fill")
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .help("Record the session: the Mac transcribes as the room talks — on this machine, nothing sent anywhere — and Stop distills the key sentences and keywords into this note")
    }

    private var liveTail: String {
        let joined = (recorder.finalizedTranscript + " " + recorder.volatileTail)
            .trimmingCharacters(in: .whitespaces)
        return String(joined.suffix(90))
    }

    private func stopRecording() async {
        guard let result = await recorder.stopAndDistill() else { return }
        if !result.keywords.isEmpty {
            state.mutateNoteFile(doc) { $0 = NoteAnalysis.writingTopics(result.keywords, to: $0) }
        }
        var sections = ""
        if !result.keySentences.isEmpty {
            sections += "\n\n## Key Sentences\n\n"
                + result.keySentences.joined(separator: "\n\n")
        }
        if !result.keywords.isEmpty {
            sections += "\n\n## Keywords\n\n" + result.keywords.joined(separator: ", ")
        }
        sections += "\n\n## Transcript\n\n" + result.transcript
        appendSections(sections)
    }

    private func flushOnClose() {
        guard recorder.phase == .recording else { return }
        let transcript = recorder.abandon()
        guard !transcript.isEmpty else { return }
        state.mutateNoteFile(doc) { fresh in
            var body = fresh.body ?? []
            body.append(LiquidDoc.Paragraph(
                id: uniqueParagraphID("session-transcript-heading", among: body),
                heading: 2, text: "Transcript"))
            body.append(LiquidDoc.Paragraph(
                id: uniqueParagraphID("session-transcript", among: body),
                heading: nil, text: transcript))
            fresh.body = body
        }
    }

    private func uniqueParagraphID(_ preferred: String,
                                   among body: [LiquidDoc.Paragraph]) -> String {
        var id = preferred
        var counter = 1
        while body.contains(where: { $0.id == id }) {
            counter += 1
            id = "\(preferred)-\(counter)"
        }
        return id
    }
}
#endif
