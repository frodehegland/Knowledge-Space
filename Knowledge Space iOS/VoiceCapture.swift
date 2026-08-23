import SwiftUI
import UIKit
import AVFoundation
import Speech
import EventKit
import AppIntents
import os

private let voiceLog = Logger(subsystem: "com.origami.notes", category: "voice")

/// Voice capture for Origami Text, ported from Knowledge Space and
/// re-aimed at the Origami format: speak, watch the live transcript,
/// correct it by hand, save — and the words become an ordinary note
/// document in the community folder. A voice note has no real subject,
/// so its first four words stand in as the title and the body keeps the
/// whole transcription; the place and moment travel as the note's
/// location field and creation instant, which readers show once, at the
/// bottom. Saved notes can also be placed, at their spoken moment, into
/// a dedicated "Origami Text" calendar.

// MARK: - Live dictation

/// Live dictation using AVAudioEngine + SFSpeechRecognizer, on-device
/// recognition preferred when the device supports it. Publishes a live
/// transcript the capture view displays as the user speaks.
///
/// Long notes are the point, so nothing here imposes a time limit: the
/// screen stays awake while recording, a recognition task that ends on
/// its own (the server's one-minute ceiling, a long silence) is replaced
/// mid-recording without losing a word, and an interruption (a call,
/// Siri) resumes when the system allows it.
@MainActor @Observable
final class SpeechRecorder {

    enum State: Equatable {
        case idle
        case recording
        case denied(String)   // human-readable reason
    }

    private(set) var state: State = .idle
    var transcript: String = ""

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Text already in the transcript when recording (re)starts —
    /// including the user's hand corrections — which a new dictation
    /// pass appends to rather than replaces.
    private var committedText = ""
    /// The longest transcription seen for the current recognition task.
    /// The recognizer can revise its guess downward at the end of a
    /// segment — sometimes to almost nothing — so committing the longest
    /// seen, not the last, keeps a finished segment from being wiped.
    private var bestSegment = ""

    /// Identifies the live recognition task, so callbacks from a task
    /// that was already replaced by a restart are ignored.
    private var taskGeneration = 0
    /// When the live task began. A task that dies this young failed;
    /// one that ran a while merely met the recognizer's natural limits.
    private var taskStartedAt = Date()
    private var rapidFailures = 0
    /// Recording was cut off by a call or Siri; resume when it ends.
    private var resumeAfterInterruption = false
    // Removed in deinit, which is nonisolated; NotificationCenter's
    // removeObserver is thread-safe.
    nonisolated(unsafe) private var interruptionObserver: (any NSObjectProtocol)?

    init() {
        recognizer = SFSpeechRecognizer(locale: Locale.current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-GB"))
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsValue = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor [weak self] in
                self?.handleInterruption(typeValue: typeValue, optionsValue: optionsValue)
            }
        }
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    /// Requests speech + microphone permission; true when both granted.
    func requestPermissions() async -> Bool {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else {
            state = .denied("Speech recognition permission was not granted. You can enable it in Settings → Privacy → Speech Recognition.")
            return false
        }
        let micGranted = await AVAudioApplication.requestRecordPermission()
        guard micGranted else {
            state = .denied("Microphone permission was not granted. You can enable it in Settings → Privacy → Microphone.")
            return false
        }
        return true
    }

    func start() throws {
        guard state != .recording else { return }
        resumeAfterInterruption = false

        // Whatever is on screen now — earlier segments plus any hand
        // corrections — becomes the immutable base this pass appends to.
        committedText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        bestSegment = ""
        transcript = committedText

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        guard let recognizer, recognizer.isAvailable else {
            state = .denied("Speech recognition is not available on this device right now.")
            UIApplication.shared.isIdleTimerDisabled = false
            return
        }

        taskGeneration += 1
        let generation = taskGeneration
        taskStartedAt = Date()
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor [weak self] in
                // Ignore results that land after stop() or from a task a
                // restart already replaced — the user may be editing the
                // transcript, and a late result must not overwrite them.
                guard let self, generation == self.taskGeneration,
                      self.state == .recording else { return }
                if let text {
                    // The recognizer revises its running transcription
                    // downward mid-task — and after ~15–20s often resets its
                    // hypothesis to a short string. A big drop from the
                    // longest we have seen is that reset: bank the longest as
                    // a committed segment and start a fresh one, so nothing is
                    // lost and the newest words still appear.
                    if self.bestSegment.count > 40,
                       text.count < self.bestSegment.count / 2 {
                        self.commitSegment()
                    }
                    if text.count > self.bestSegment.count { self.bestSegment = text }
                    // Show the longest seen, never the latest — displaying the
                    // latest is what made text vanish while still recording.
                    self.transcript = self.committedText.isEmpty
                        ? self.bestSegment
                        : self.committedText + " " + self.bestSegment
                    self.rapidFailures = 0
                }
                // The recognizer finishing on its own — a final result, the
                // server's one-minute ceiling, a long silence — is not the
                // user stopping: keep recording with a fresh task.
                if isFinal || failed {
                    self.recognitionEnded()
                }
            }
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        state = .recording
        // Long notes are spoken without touching the screen; don't let
        // auto-lock end them.
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func stop() {
        guard state == .recording else { return }
        commitSegment()
        tearDown()
        state = .idle
    }

    /// Folds the current recognition segment into the finalised text,
    /// keeping the longest version seen rather than the recognizer's
    /// possibly shortened last guess — so recycling the task or stopping
    /// never loses a completed segment.
    private func commitSegment() {
        let segment = bestSegment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !segment.isEmpty {
            committedText = committedText.isEmpty ? segment : committedText + " " + segment
        }
        transcript = committedText
        bestSegment = ""
    }

    /// Stops the engine and the task without deciding what comes next.
    private func tearDown() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// The recognition task ended while the user is still recording.
    /// The finished segment is committed first, so recycling the task
    /// keeps every word. Genuine failures die young and repeatedly —
    /// give up after several in a row; anything else restarts.
    private func recognitionEnded() {
        if Date().timeIntervalSince(taskStartedAt) < 1 {
            rapidFailures += 1
        } else {
            rapidFailures = 0
        }
        // Save what was said before doing anything else.
        commitSegment()
        guard rapidFailures < 6 else {
            rapidFailures = 0
            stop()
            return
        }
        tearDown()
        state = .idle
        do {
            try start()
        } catch {
            voiceLog.error("SpeechRecorder: could not restart recognition: \(error.localizedDescription)")
        }
    }

    private func handleInterruption(typeValue: UInt?, optionsValue: UInt?) {
        guard let typeValue,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            // A call or Siri took the microphone. Keep the words; plan
            // to pick the recording back up when the system allows.
            guard state == .recording else { return }
            stop()
            resumeAfterInterruption = true
        case .ended:
            guard resumeAfterInterruption else { return }
            resumeAfterInterruption = false
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue ?? 0)
            if options.contains(.shouldResume) {
                try? start()
            }
        @unknown default:
            break
        }
    }
}

// MARK: - The note's shape

/// Shapes a raw transcription into a note. A voice note has no real
/// subject the way a typed note does, so the first four words of the
/// transcription stand in as its title, while the body keeps the full
/// transcription — first four words included. The place and the moment
/// are not written into the text: they travel as the note's location
/// field and creation instant, and readers show them once, at the
/// bottom.
enum TranscriptParser {

    struct ParsedNote {
        let title: String
        let bodyText: String
    }

    static func note(from transcript: String) -> ParsedNote {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedNote(title: title(for: text), bodyText: text)
    }

    /// The first four words, standing in for the subject a voice note
    /// never really has. The same rule re-derives the title when a
    /// voice note's body is edited.
    static func title(for text: String) -> String {
        let title = text.split(whereSeparator: \.isWhitespace)
            .prefix(4)
            .joined(separator: " ")
        return title.isEmpty ? "Untitled" : title
    }

    /// Whether a note reads as voice-created: its title is exactly the
    /// first four words of its body — derived, so not worth showing.
    static func isVoiceNote(title: String, bodyText: String) -> Bool {
        !bodyText.isEmpty && title == self.title(for: bodyText)
    }
}

// MARK: - The calendar

/// Writes saved voice notes into a dedicated "Origami Text" calendar
/// via EventKit, at the moment they were spoken. Full access is needed
/// because a *dedicated* calendar cannot be found or created with
/// write-only access; the app never reads existing events. The note's
/// place travels as the event's location, per the format: a place name,
/// never coordinates.
@MainActor
final class NoteCalendar {

    static let shared = NoteCalendar()

    private let store = EKEventStore()
    private let calendarTitle = "Origami Text"
    private let calendarIDKey = "noteCalendarIdentifier"
    /// Note id → event id, so deleting a note removes its event.
    private let eventMapKey = "noteCalendarEvents"

    /// Requests calendar access if needed; true when writing is possible.
    func ensureAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return true
        case .notDetermined:
            return (try? await store.requestFullAccessToEvents()) ?? false
        default:
            return false
        }
    }

    /// Finds (or creates) the dedicated calendar, preferring the user's
    /// iCloud account so it syncs to their Mac and other devices.
    private func notesCalendar() -> EKCalendar? {
        if let id = UserDefaults.standard.string(forKey: calendarIDKey),
           let calendar = store.calendar(withIdentifier: id) {
            return calendar
        }
        if let existing = store.calendars(for: .event)
            .first(where: { $0.title == calendarTitle }) {
            UserDefaults.standard.set(existing.calendarIdentifier, forKey: calendarIDKey)
            return existing
        }

        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = calendarTitle
        calendar.cgColor = CGColor(red: 0.85, green: 0.55, blue: 0.25, alpha: 1)

        let iCloudSource = store.sources.first {
            $0.sourceType == .calDAV && $0.title.localizedCaseInsensitiveContains("icloud")
        }
        let fallbackSource = store.defaultCalendarForNewEvents?.source
            ?? store.sources.first { $0.sourceType == .local }
        guard let source = iCloudSource ?? fallbackSource else { return nil }
        calendar.source = source

        do {
            try store.saveCalendar(calendar, commit: true)
            UserDefaults.standard.set(calendar.calendarIdentifier, forKey: calendarIDKey)
            return calendar
        } catch {
            voiceLog.error("NoteCalendar: could not create calendar: \(error.localizedDescription)")
            return nil
        }
    }

    /// A one-minute marker at the note's moment; true on success.
    func addEvent(for doc: LiquidDoc, bodyText: String) async -> Bool {
        guard await ensureAccess(), let calendar = notesCalendar() else { return false }

        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = doc.title
        event.startDate = doc.created
        event.endDate = doc.created.addingTimeInterval(60)
        event.notes = bodyText.isEmpty ? nil : bodyText
        event.location = doc.location

        do {
            try store.save(event, span: .thisEvent, commit: true)
            var map = UserDefaults.standard.dictionary(forKey: eventMapKey) as? [String: String] ?? [:]
            map[doc.id] = event.eventIdentifier
            UserDefaults.standard.set(map, forKey: eventMapKey)
            return true
        } catch {
            voiceLog.error("NoteCalendar: could not save event: \(error.localizedDescription)")
            return false
        }
    }

    /// Removes the event belonging to a deleted note, if there is one.
    func removeEvent(forNote id: String) {
        var map = UserDefaults.standard.dictionary(forKey: eventMapKey) as? [String: String] ?? [:]
        guard let eventID = map.removeValue(forKey: id) else { return }
        UserDefaults.standard.set(map, forKey: eventMapKey)
        guard let event = store.event(withIdentifier: eventID) else { return }
        try? store.remove(event, span: .thisEvent, commit: true)
    }
}

// MARK: - The capture view

/// Arrive by the Record Note button (or by Siri) and speak; the
/// transcript builds live and can be corrected by hand once recording
/// stops. Done stops the recording and turns the words into a note in
/// the community folder — and, when the toggle is on, a marker in the
/// Origami Text calendar at the spoken moment.
struct VoiceCaptureView: View {
    @Environment(NotesModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var recorder = SpeechRecorder()
    /// Fixed when recording starts — the note belongs to when it was
    /// spoken, not when saved.
    @State private var captureDate: Date?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @AppStorage("voiceNoteToCalendar") private var addToCalendar = true
    /// Checked, the spoken note is born a To Do — the standing travels
    /// in the file, so it lists under To Do on every device.
    @State private var isToDo = false
    /// Important — a binary flag of its own, orange like the Mac's and
    /// like the typing sheet's; it carries in the file beside the standing.
    @State private var isImportant = false
    @State private var filingKind: LiquidDoc.DocumentType = .note
    @State private var filingFolder: String? = nil
    /// Once dictation is done and the person taps in to edit, the big
    /// record circle steps aside — the keyboard's own mic serves from there.
    @FocusState private var editorFocused: Bool

    private var isRecording: Bool { recorder.state == .recording }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let captureDate {
                    Text(captureDate, format: .dateTime.weekday().day().month().hour().minute())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                transcriptEditor

                if case .denied(let reason) = recorder.state {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Toggle("Add to Calendar", isOn: $addToCalendar)
                    .padding(.horizontal)

                Toggle("To Do", isOn: $isToDo)
                    .padding(.horizontal)

                Toggle("Important", isOn: $isImportant)
                    .tint(.orange)
                    .padding(.horizontal)

                filingMenu
                    .padding(.horizontal)

                if !editorFocused {
                    recordButton
                        .padding(.bottom, 8)
                }
            }
            .padding()
            // No heading — the note names itself from its first words.
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        recorder.stop()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    // Done works mid-dictation: it stops the recorder
                    // and saves what was said in one tap.
                    Button("Done") { Task { await save() } }
                        .disabled((recorder.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                   && !isRecording) || isSaving)
                }
            }
        }
        .interactiveDismissDisabled(isRecording)
        .task { await model.refreshFilingFolders() }
        .task {
            if !isRecording {
                await toggleRecording()
            }
        }
    }

    private var transcriptEditor: some View {
        TextEditor(text: $recorder.transcript)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .topLeading) {
                if recorder.transcript.isEmpty && !isRecording {
                    Text("Tap the microphone and start speaking. The first four words name the note; the place and time travel with it.")
                        .foregroundStyle(.tertiary)
                        .padding(16)
                        .allowsHitTesting(false)
                }
            }
            .focused($editorFocused)
            .disabled(isRecording)   // hands off while dictating
    }

    private var filingMenu: some View {
        let customFolders = model.filingFolders.filter {
            !["thoughts", "inspirations", "journal", "archived"]
                .contains($0.lowercased())
        }
        let label: String = {
            if let f = filingFolder { return model.displayName(for: f) }
            return filingKind == .note ? "Note" : filingKind.displayName
        }()
        return Menu {
            ForEach([LiquidDoc.DocumentType.note, .thought, .journal, .inspiration],
                    id: \.self) { k in
                Button(k == .note ? "Note" : k.displayName) {
                    filingKind = k
                    filingFolder = nil
                }
            }
            if !customFolders.isEmpty {
                Divider()
                ForEach(customFolders, id: \.self) { folder in
                    // The alias shows; the canonical name files.
                    Button(model.displayName(for: folder)) {
                        filingFolder = folder
                        filingKind = .note
                    }
                }
            }
        } label: {
            HStack {
                Text("File under:")
                    .foregroundStyle(.secondary)
                Text(label)
                    .fontWeight(.medium)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var recordButton: some View {
        Button {
            Task { await toggleRecording() }
        } label: {
            ZStack {
                Circle()
                    .fill(isRecording ? Color.red : Color.accentColor)
                    .frame(width: 84, height: 84)
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white)
            }
        }
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
        .sensoryFeedback(.impact, trigger: isRecording)
    }

    private func toggleRecording() async {
        if isRecording {
            recorder.stop()
            return
        }
        guard await recorder.requestPermissions() else { return }
        do {
            if captureDate == nil { captureDate = Date() }
            model.refreshPlace()
            try recorder.start()
        } catch {
            errorMessage = "Could not start recording: \(error.localizedDescription)"
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        if isRecording { recorder.stop() }
        guard !recorder.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            dismiss()
            return
        }

        let parsed = TranscriptParser.note(from: recorder.transcript)
        guard let doc = model.createNote(title: parsed.title,
                                         bodyText: parsed.bodyText,
                                         created: captureDate ?? .now,
                                         asToDo: isToDo,
                                         important: isImportant,
                                         kind: filingKind,
                                         filedUnder: filingFolder) else {
            // The reason is in model.lastError, shown by the home view.
            dismiss()
            return
        }
        if addToCalendar {
            let added = await NoteCalendar.shared.addEvent(for: doc, bodyText: parsed.bodyText)
            if !added {
                errorMessage = "The note was saved, but could not be added to the calendar. You can allow access in Settings → Privacy → Calendars."
                return
            }
        }
        dismiss()
    }
}

// MARK: - Siri

/// Opens the app straight into voice capture, recording with its own
/// on-device recognizer — works with no connection at all.
struct StartVoiceNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "New Voice Note"
    static var description = IntentDescription("Opens Origami Text recording, ready to take a note.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotesModel.shared.voiceCaptureRequested = true
        return .result()
    }
}

/// The invisible flow: Siri asks what the note should say, transcribes
/// it itself, and the note is saved without opening the app.
struct AddNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Note"
    static var description = IntentDescription("Dictate a note and save it straight into your community folder — and your calendar.")

    @Parameter(title: "Note", requestValueDialog: "What should the note say?")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(dialog: "I didn't catch anything, so nothing was saved.")
        }
        let model = NotesModel.shared
        let parsed = TranscriptParser.note(from: trimmed)
        guard let doc = model.createNote(title: parsed.title, bodyText: parsed.bodyText) else {
            return .result(dialog: "\(model.lastError ?? "The note could not be saved.")")
        }
        if UserDefaults.standard.object(forKey: "voiceNoteToCalendar") as? Bool ?? true {
            _ = await NoteCalendar.shared.addEvent(for: doc, bodyText: parsed.bodyText)
        }
        return .result(dialog: "Noted.")
    }
}

struct OrigamiTextShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        // Every phrase must contain the app name — or an alternative
        // app name from Info.plist ("Origami"), which is what lets
        // "Origami, take this down" and "Origami note" work. The
        // flagship phrases open the app recording with its own
        // on-device recognizer; "Tell Origami" stays fully inside Siri.
        AppShortcut(
            intent: StartVoiceNoteIntent(),
            phrases: [
                "\(.applicationName)",
                "\(.applicationName) note",
                "\(.applicationName), take this down",
                "\(.applicationName) take this down",
                "Take this down in \(.applicationName)",
                "Record in \(.applicationName)",
                "Dictate to \(.applicationName)",
                "New voice note in \(.applicationName)"
            ],
            shortTitle: "Voice Note",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: AddNoteIntent(),
            phrases: [
                "Tell \(.applicationName)",
                "Add a note to \(.applicationName)",
                "New note in \(.applicationName)"
            ],
            shortTitle: "Add Note",
            systemImageName: "square.and.pencil"
        )
    }
}
