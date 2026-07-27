import SwiftUI
import CoreLocation
import UniformTypeIdentifiers
import os

private let log = Logger(subsystem: "com.origami.notes", category: "notes")

/// The phone is a capture app, and the format document's capture fixture
/// (ORIGAMI-DOCUMENT-FORMAT.md §11) is the whole of what it may write.
/// This contract pins the initial JSON to exactly that shape: the §11
/// fields, plus the `about` preamble every save carries, the `links` the
/// body's addresses imply, and the `draft` flag a phone note starts with.
/// A debug build halts the moment a field creeps in or goes missing,
/// naming the drift; a release build never blocks a note from being
/// written, but logs it. If a change to the shape is deliberate, update
/// the format document and this contract together.
private nonisolated enum CaptureContract {
    /// Every top-level key a freshly captured note may carry.
    static let allowedKeys: Set<String> = [
        "about", "format", "id", "title", "author", "created",
        "body", "links", "draft", "documentType", "location",
    ]
    /// The keys the standard requires of every text document.
    static let requiredKeys: Set<String> = [
        "format", "id", "title", "author", "created", "body",
    ]

    static func check(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any] else {
            log.error("CaptureContract: initial note JSON is not an object")
            assertionFailure("CaptureContract: initial note JSON is not an object")
            return
        }
        let present = Set(json.keys)
        let unexpected = present.subtracting(allowedKeys).sorted()
        let missing = requiredKeys.subtracting(present).sorted()
        guard !unexpected.isEmpty || !missing.isEmpty else { return }
        var drift: [String] = []
        if !unexpected.isEmpty {
            drift.append("beyond the capture shape: \(unexpected.joined(separator: ", "))")
        }
        if !missing.isEmpty {
            drift.append("missing required fields: \(missing.joined(separator: ", "))")
        }
        let message = "CaptureContract: initial note JSON drifted — \(drift.joined(separator: "; "))"
        log.error("\(message)")
        assertionFailure(message)
    }
}

/// Origami Text for iOS: the capture end of the format. Notes only —
/// create, edit, done. Every note is an ordinary Origami document
/// (`documentType: "note"`) written straight into the community folder,
/// so it is on the Mac and in the headset the moment the folder syncs.
/// A note carries the place it was made (reverse-geocoded on creation,
/// per the format: a free-form place name, not coordinates) and never
/// shows an author — a note is always its author's own. Letters and the
/// library's views are deliberately absent; the phone captures, the
/// larger screens weave.
@main
struct OrigamiNotesApp: App {
    @State private var model = NotesModel.shared

    var body: some Scene {
        WindowGroup {
            NotesHomeView()
                .environment(model)
        }
    }
}

// MARK: - The model

/// The notes as the community folder holds them, plus the identity and
/// place a new note needs. Rescans on demand and when the app returns to
/// the foreground.
@MainActor @Observable
final class NotesModel {
    /// One model for the app and for Siri — App Intents save through
    /// the same folder and list the views are showing.
    static let shared = NotesModel()

    /// Flipped by Siri ("Origami, take this down") so the home view
    /// presents voice capture the moment the app opens.
    var voiceCaptureRequested = false

    private(set) var notes: [LiquidDoc] = []
    private(set) var folderURL: URL?

    /// The most recent failure, in words the alert can show. Every path
    /// that used to fail silently reports here instead.
    var lastError: String?

    private static let bookmarkKey = "communityFolderBookmark"
    private static let authorKey = "authorName"
    private let locationFinder = LocationFinder()

    /// The place the device last resolved — attached to a note at
    /// creation, refreshed in the background while the app is open.
    private(set) var currentPlace: String?

    /// Every identity card found in the community folder — each an
    /// ordinary Origami document (`documentType: "card"`) carrying one
    /// person's public record. Identity is never a typed name here: the
    /// user adopts their card from the folder. Cards are made and edited
    /// on the larger screens; the phone only reads them.
    private(set) var cards: [LiquidDoc] = []

    var authorName: String {
        get { UserDefaults.standard.string(forKey: Self.authorKey) ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.authorKey)
            // The list shows only this name's notes — refilter for it.
            rescan()
        }
    }

    init() {
        restoreFolder()
        locationFinder.onPlace = { [weak self] place in
            self?.currentPlace = place
        }
        locationFinder.begin()
    }

    /// Called when a note is about to be made, so the place is fresh.
    func refreshPlace() {
        locationFinder.begin()
    }

    // MARK: The folder

    func openFolder(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            lastError = "iOS did not grant access to that folder. Please choose it again."
            log.error("openFolder: security scope refused for \(url.path)")
            return
        }
        do {
            let bookmark = try url.bookmarkData()
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        } catch {
            log.error("openFolder: bookmark failed: \(error.localizedDescription)")
        }
        folderURL = url
        rescan()
    }

    private func restoreFolder() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else {
            log.error("restoreFolder: could not resolve or access the saved folder bookmark")
            return
        }
        folderURL = url
        rescan()
    }

    /// The user's own notes, newest first. The folder holds the whole
    /// community's documents, but the phone is the capture end: it
    /// shows only what its user wrote — the larger screens weave.
    ///
    /// The scan reads and decodes every document in the folder, so it
    /// runs off the main thread — the first call happens during app
    /// init, and a synchronous scan of a large iCloud folder there
    /// holds the launch screen until the watchdog kills the app.
    func rescan() {
        guard let folderURL else { return }
        let author = authorName
        let cardType = IdentityCard.documentType
        Task.detached(priority: .userInitiated) {
            let (foundNotes, foundCards) = Self.scan(folder: folderURL, author: author,
                                                     cardType: cardType)
            await MainActor.run {
                // Through the singleton, not a captured self — rescan's
                // first call is inside init, before self can travel.
                let model = NotesModel.shared
                model.notes = foundNotes
                model.cards = foundCards
            }
        }
    }

    private nonisolated static func scan(folder folderURL: URL, author: String,
                                         cardType: String) -> ([LiquidDoc], [LiquidDoc]) {
        // Documents made elsewhere may exist here only as hidden
        // ".<name>.icloud" placeholders, and asking iCloud for the
        // folder alone does not reliably fetch its contents — ask for
        // each by its real name, so the next rescan (foregrounding,
        // pull-to-refresh) finds what has landed.
        try? FileManager.default.startDownloadingUbiquitousItem(at: folderURL)
        if let placeholders = FileManager.default.enumerator(
            at: folderURL, includingPropertiesForKeys: nil,
            options: [.skipsPackageDescendants]) {
            for case let url as URL in placeholders
            where url.pathExtension.lowercased() == "icloud" {
                var name = url.lastPathComponent
                if name.hasPrefix(".") { name.removeFirst() }
                name = String(name.dropLast(".icloud".count))
                guard !name.isEmpty else { continue }
                let real = url.deletingLastPathComponent().appendingPathComponent(name)
                try? FileManager.default.startDownloadingUbiquitousItem(at: real)
            }
        }
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let enumerator = FileManager.default.enumerator(
            at: folderURL, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var foundNotes: [LiquidDoc] = []
        var foundCards: [LiquidDoc] = []
        while let url = enumerator?.nextObject() as? URL {
            guard LiquidDoc.isDocumentFile(url),
                  let data = try? Data(contentsOf: url),
                  let doc = try? LiquidDoc.decode(data: data, fileURL: url)
            else { continue }
            if doc.documentType == cardType {
                foundCards.append(doc)
            } else if doc.documentType == LiquidDoc.DocumentType.note.rawValue,
                      isOwn(doc, author: author) {
                foundNotes.append(doc)
            }
        }
        return (foundNotes.sorted { $0.listedDate > $1.listedDate },
                foundCards.sorted {
                    $0.author.localizedCaseInsensitiveCompare($1.author) == .orderedAscending
                })
    }

    // MARK: The card

    /// The user's own card in the folder, when one carries their name.
    var ownCard: LiquidDoc? {
        guard !authorName.isEmpty else { return nil }
        return cards.first { isOwn($0) }
    }

    /// "This card is mine" — identity adopted from the folder's shared
    /// record, never typed in as a bare name.
    func adopt(card doc: LiquidDoc) {
        authorName = doc.author
    }

    // MARK: Notes

    func isOwn(_ doc: LiquidDoc) -> Bool {
        Self.isOwn(doc, author: authorName)
    }

    private nonisolated static func isOwn(_ doc: LiquidDoc, author: String) -> Bool {
        doc.author.trimmingCharacters(in: .whitespaces)
            .caseInsensitiveCompare(author.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }

    /// A new note, written into the folder at once — file first, edits
    /// follow. The place travels in at creation, per the format. Voice
    /// capture passes the spoken title, body, and moment; the bare call
    /// makes the empty note the editor opens on.
    func createNote(title: String = "Untitled", bodyText: String = "",
                    created: Date = .now) -> LiquidDoc? {
        guard let folderURL else {
            lastError = "No community folder is open. Choose the folder first."
            return nil
        }
        guard !authorName.isEmpty else {
            lastError = "Set your name first — a note carries its author."
            return nil
        }
        // Collision detection reaches the whole folder, not just the
        // notes this phone shows: the file about to be written must not
        // silently replace a document already answering to the address.
        let id = LiquidAddress.makeID(author: authorName, created: created) { candidate in
            self.notes.contains { $0.id == candidate }
                || FileManager.default.fileExists(
                    atPath: folderURL.appendingPathComponent(candidate)
                        .appendingPathExtension(LiquidDoc.fileExtension).path)
        }
        let body = LiquidDoc.parseBody(from: bodyText)
        // A phone-captured note starts as a draft; the flag travels in
        // the file, so Knowledge Space on the Mac lists it under Drafts
        // alone until it is published there.
        let doc = LiquidDoc(format: LiquidDoc.knownFormat,
                            id: id,
                            title: title,
                            author: authorName,
                            created: created,
                            body: body,
                            links: LiquidDoc.detectedLinks(in: body),
                            wraps: nil,
                            draft: true,
                            documentType: LiquidDoc.DocumentType.note.rawValue,
                            location: currentPlace,
                            fileURL: folderURL.appendingPathComponent(id)
                                .appendingPathExtension(LiquidDoc.fileExtension))
        do {
            let data = try doc.jsonData()
            CaptureContract.check(data)
            try data.write(to: doc.fileURL, options: .atomic)
            notes.insert(doc, at: 0)
            return doc
        } catch {
            lastError = "Could not write the note: \(error.localizedDescription)"
            log.error("createNote: write failed at \(doc.fileURL.path): \(error.localizedDescription)")
            return nil
        }
    }

    /// The edited note, rewritten in place. Identity, creation instant,
    /// and place stay as captured; title and body are the user's.
    func save(_ doc: LiquidDoc, title: String, bodyText: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let body = LiquidDoc.parseBody(from: bodyText)
        // Title, body, and the links the body implies are the phone's
        // to change — nothing else. Copy-and-mutate carries every other
        // field through, so a standing or attention set on the Mac
        // survives an edit made here.
        var updated = doc
        updated.title = trimmedTitle.isEmpty ? "Untitled" : trimmedTitle
        updated.body = body
        updated.links = LiquidDoc.detectedLinks(in: body)
        updated.wraps = nil
        do {
            try updated.jsonData().write(to: updated.fileURL, options: .atomic)
        } catch {
            lastError = "Could not save the note: \(error.localizedDescription)"
            log.error("save: write failed at \(updated.fileURL.path): \(error.localizedDescription)")
            return
        }
        if let index = notes.firstIndex(where: { $0.id == doc.id }) {
            notes[index] = updated
        }
    }

    func delete(_ doc: LiquidDoc) {
        guard isOwn(doc) else { return }
        try? FileManager.default.removeItem(at: doc.fileURL)
        NoteCalendar.shared.removeEvent(forNote: doc.id)
        notes.removeAll { $0.id == doc.id }
    }

    func note(id: String) -> LiquidDoc? {
        notes.first { $0.id == id }
    }

    /// Whether the note's file has finished uploading to iCloud — nil
    /// when the folder is not iCloud's, or the answer is unknowable.
    /// The debugging use: a note without its bullet has not left the
    /// phone, so the Mac cannot have it yet.
    func isUploaded(_ doc: LiquidDoc) -> Bool? {
        guard let values = try? doc.fileURL.resourceValues(
            forKeys: [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey]),
              values.isUbiquitousItem == true else { return nil }
        return values.ubiquitousItemIsUploaded
    }
}

/// One-shot place finding: current location, reverse-geocoded to the
/// most natural short name — sublocality, locality, and country where
/// the placemark has them ("Wimbledon, London, United Kingdom"), per
/// the format's location convention. The country comes last; the Mac's
/// Notes ▸ Locations uses it as its section heading.
private final class LocationFinder: NSObject, CLLocationManagerDelegate {
    var onPlace: (@MainActor (String) -> Void)?
    private let manager = CLLocationManager()

    func begin() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.requestWhenInUseAuthorization()
        manager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task {
            // A spot the user has named claims the stamp first: their
            // chosen name, with the surroundings remembered at naming —
            // detail only where the user granted it, by naming.
            if let named = await MyPlaces.shared.stamp(near: location) {
                await MainActor.run { [onPlace] in onPlace?(named) }
                return
            }
            guard let placemark = try? await CLGeocoder()
                .reverseGeocodeLocation(location).first else { return }
            let parts = [placemark.subLocality, placemark.locality, placemark.country]
                .compactMap { $0 }
            let place = parts.isEmpty
                ? (placemark.name ?? placemark.administrativeArea ?? "")
                : parts.joined(separator: ", ")
            guard !place.isEmpty else { return }
            await MainActor.run { [onPlace] in onPlace?(place) }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // No place, no field — the note simply travels without one.
    }
}

// MARK: - The views

/// The list: the user's own notes, newest on top. The row says when
/// and where — never who, since every note here is the user's own; a
/// green bullet at the row's end says the note has uploaded to iCloud.
struct NotesHomeView: View {
    @Environment(NotesModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var choosingFolder = false
    @State private var choosingCard = false
    @State private var writingNote = false
    @State private var capturingVoice = false
    @State private var settingUp = false
    @State private var namingPlaces = false

    var body: some View {
        NavigationStack {
            Group {
                if model.folderURL == nil {
                    ContentUnavailableView {
                        Label("No Community Folder", systemImage: "folder")
                    } description: {
                        Text("Choose the folder your community shares. Notes you make here appear on your Mac and in the headset the moment it syncs.")
                    } actions: {
                        Button("Choose Folder…") { choosingFolder = true }
                    }
                } else {
                    notesList
                }
            }
            .navigationDestination(for: String.self) { id in
                NoteEditorView(docID: id)
            }
            // The three doors at the bottom: speak a note, set up, write
            // a note. Set-up (the gear) is always open; the other two
            // wait for a folder and a name.
            .safeAreaInset(edge: .bottom) {
                HStack {
                    // Capture never dead-ends: without an identity the
                    // tap opens the card flow instead of doing nothing.
                    Button {
                        if model.authorName.isEmpty {
                            askForIdentityIfNeeded()
                        } else {
                            capturingVoice = true
                        }
                    } label: {
                        Image(systemName: "mic.fill")
                    }
                    .accessibilityLabel("Record Note")
                    .disabled(model.folderURL == nil)

                    Spacer()

                    Button {
                        settingUp = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Set Up")

                    Spacer()

                    NewNoteButton(writingNote: $writingNote,
                                  onNeedsIdentity: askForIdentityIfNeeded)
                        .labelStyle(.iconOnly)
                }
                .font(.title2)
                .padding(.horizontal, 44)
                .padding(.vertical, 12)
                .background(.bar)
            }
        }
        .confirmationDialog("Set Up", isPresented: $settingUp) {
            Button("Choose Shared Folder…") { choosingFolder = true }
            Button("Your Card…") { choosingCard = true }
            Button("My Places…") { namingPlaces = true }
        } message: {
            Text("Pick the folder your community shares, or choose your card from it — your public identity lives in the shared folder. Notes carry its name as their author.")
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                model.openFolder(url)
                // The folder is the source of identity too: once it is
                // open, the user adopts their card or fills one in.
                Task { askForIdentityIfNeeded() }
            }
        }
        .sheet(isPresented: $capturingVoice) {
            VoiceCaptureView()
        }
        .sheet(isPresented: $writingNote) {
            NewNoteView()
        }
        .sheet(isPresented: $namingPlaces) {
            MyPlacesView()
        }
        .alert("Your Card", isPresented: $choosingCard) {
            ForEach(model.cards) { card in
                Button(card.author) { model.adopt(card: card) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.cards.isEmpty
                 ? "The shared folder holds no cards yet. Fill in your card in Knowledge Space on the Mac — it appears here once the folder syncs."
                 : "The folder holds these cards. Choose the one that is yours — notes carry your card's name as their author.")
        }
        .alert("Something Went Wrong", isPresented: Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.lastError ?? "")
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                model.rescan()
                model.refreshPlace()
            }
        }
        // Siri opened the app to take a note down.
        .onChange(of: model.voiceCaptureRequested) {
            if model.voiceCaptureRequested {
                model.voiceCaptureRequested = false
                capturingVoice = true
            }
        }
        .onAppear {
            askForIdentityIfNeeded()
            if model.voiceCaptureRequested {
                model.voiceCaptureRequested = false
                capturingVoice = true
            }
        }
    }

    /// Identity is never asked for as a name — and never typed in here
    /// at all. With the folder open, the user adopts their card from
    /// it; when the folder holds no cards yet, the same alert explains
    /// that the card is made on the Mac and arrives with the sync.
    private func askForIdentityIfNeeded() {
        guard model.folderURL != nil, model.authorName.isEmpty else { return }
        choosingCard = true
    }

    private var notesList: some View {
        List {
            ForEach(notesByDay, id: \.day) { group in
                Section(heading(for: group.day)) {
                    ForEach(group.notes) { doc in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(doc.title)
                                    .fontWeight(.medium)
                                    .lineLimit(2)
                                if let location = doc.location {
                                    Text(location)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            // The bullet says the note has not yet left the
                            // phone: still uploading to iCloud, so the Mac
                            // cannot have it. It disappears once uploaded.
                            if model.isOwn(doc), model.isUploaded(doc) == false {
                                Spacer(minLength: 8)
                                Circle()
                                    .fill(.primary)
                                    .frame(width: 7, height: 7)
                                    .accessibilityLabel("Not yet uploaded to iCloud")
                            }
                        }
                        // The link hides behind the row so no disclosure
                        // chevron appears — the whole row stays tappable.
                        .background {
                            NavigationLink(value: doc.id) { EmptyView() }
                                .opacity(0)
                        }
                        .swipeActions {
                            if model.isOwn(doc) {
                                Button("Delete", role: .destructive) { model.delete(doc) }
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if model.notes.isEmpty {
                ContentUnavailableView(
                    "No Notes Yet",
                    systemImage: "note.text",
                    description: Text("Make a note — it carries the moment and the place, and travels with the folder."))
            }
        }
        .refreshable { model.rescan() }
    }

    /// "Today" for today's notes; any other day by its full date.
    private func heading(for day: Date) -> String {
        Calendar.current.isDateInToday(day)
            ? "Today"
            : day.formatted(date: .long, time: .omitted)
    }

    /// The notes grouped by the day they are listed under, newest day
    /// first — each group becomes a dated section of the list. The rows
    /// then carry only the place; the day is said once, in the heading.
    private var notesByDay: [(day: Date, notes: [LiquidDoc])] {
        let calendar = Calendar.current
        var groups: [(day: Date, notes: [LiquidDoc])] = []
        for doc in model.notes {
            let day = calendar.startOfDay(for: doc.listedDate)
            if groups.last?.day == day {
                groups[groups.count - 1].notes.append(doc)
            } else {
                groups.append((day: day, notes: [doc]))
            }
        }
        return groups
    }
}

/// The new-note button: refreshes the place and opens the writing
/// sheet — capture should be two taps from anywhere. Nothing is saved
/// until Done. Without an identity yet, the tap opens the card flow
/// instead of doing nothing.
private struct NewNoteButton: View {
    @Environment(NotesModel.self) private var model
    @Binding var writingNote: Bool
    let onNeedsIdentity: () -> Void

    var body: some View {
        Button {
            if model.authorName.isEmpty {
                onNeedsIdentity()
            } else {
                model.refreshPlace()
                writingNote = true
            }
        } label: {
            Label("New Note", systemImage: "square.and.pencil")
        }
        .disabled(model.folderURL == nil)
    }
}

/// Writing a new note: just the writing area — no heading, no title
/// field; the first four words become the note's name when Done saves
/// it, exactly as a spoken note is named. Cancel and Done sit where
/// voice capture puts them.
struct NewNoteView: View {
    @Environment(NotesModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @FocusState private var writing: Bool

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding()
                .focused($writing)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { save() }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
        .task { writing = true }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            dismiss()
            return
        }
        let parsed = TranscriptParser.note(from: trimmed)
        // The reason for a failure is in model.lastError, shown by the
        // home view.
        _ = model.createNote(title: parsed.title, bodyText: parsed.bodyText)
        dismiss()
    }
}

/// The note itself: title and text, editable when it is the user's own,
/// read-only when it arrived from someone else. The line under the title
/// carries only the when and the where. A voice-created note — its title
/// just the first four words of its body — shows no title at all, only
/// the whole body, which carries its place and moment at the bottom.
struct NoteEditorView: View {
    @Environment(NotesModel.self) private var model
    let docID: String

    @State private var title = ""
    @State private var bodyText = ""
    @State private var loaded = false
    @State private var isVoiceNote = false
    /// Reading until the reader says Edit — the deliberate step keeps a
    /// casually opened note from silently rewriting its file, so the
    /// Mac's always-editable page and the phone rarely collide.
    @State private var isEditing = false

    private var doc: LiquidDoc? { model.note(id: docID) }
    private var isEditable: Bool { doc.map { model.isOwn($0) } ?? false }

    var body: some View {
        Group {
            if let doc {
                VStack(alignment: .leading, spacing: 8) {
                    if !isVoiceNote {
                        TextField("Title", text: $title)
                            .font(.title2.weight(.semibold))
                            .disabled(!isEditable || !isEditing)
                        Text(caption(for: doc))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Divider()
                    }
                    TextEditor(text: $bodyText)
                        .font(.body)
                        .disabled(!isEditable || !isEditing)
                        .scrollContentBackground(.hidden)
                    // A voice note shows no title or caption above — its
                    // when and where sit once, quietly, at the bottom.
                    if isVoiceNote {
                        Text(caption(for: doc))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            } else {
                ContentUnavailableView("Note Not Available", systemImage: "note.text",
                                       description: Text("This note is no longer in the folder."))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isEditable {
                ToolbarItem(placement: .primaryAction) {
                    Button(isEditing ? "Done" : "Edit") {
                        if isEditing { saveIfNeeded() }
                        isEditing.toggle()
                    }
                }
            }
        }
        .onAppear {
            guard !loaded, let doc else { return }
            loaded = true
            isVoiceNote = TranscriptParser.isVoiceNote(title: doc.title,
                                                       bodyText: doc.bodyEditingText)
            title = doc.title == "Untitled" ? "" : doc.title
            bodyText = doc.bodyEditingText
        }
        .onDisappear {
            if isEditing { saveIfNeeded() }
        }
    }

    private func caption(for doc: LiquidDoc) -> String {
        let when = doc.created.formatted(date: .abbreviated, time: .shortened)
        guard let location = doc.location else { return when }
        return "\(when) · \(location)"
    }

    private func saveIfNeeded() {
        guard isEditable, let doc else { return }
        // A voice note's title stays derived — the first four words of
        // whatever the body now says.
        let savedTitle = isVoiceNote ? TranscriptParser.title(for: bodyText) : title
        model.save(doc, title: savedTitle, bodyText: bodyText)
    }
}
