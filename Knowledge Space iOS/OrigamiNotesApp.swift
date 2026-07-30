import SwiftUI
import UIKit
import CoreLocation
import UniformTypeIdentifiers
import os

private let log = Logger(subsystem: "com.origami.notes", category: "notes")

/// The keyboard subsystem boots lazily on its first use in an app
/// session — on a physical device that first raise can lag a second or
/// more, which is why a freshly opened note used to sit unfocused for a
/// beat. Summoning and dismissing a throwaway field once, off-screen and
/// within a single runloop (so no keyboard ever animates into view),
/// warms it, so the first note the writer opens takes the keyboard at
/// once. Idempotent: it runs a single time per launch.
@MainActor
private enum KeyboardPrewarmer {
    private static var warmed = false

    static func prewarm() {
        guard !warmed else { return }
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })?
            .keyWindow else { return }
        warmed = true
        let field = UITextField(frame: .zero)
        window.addSubview(field)
        field.becomeFirstResponder()
        field.resignFirstResponder()
        field.removeFromSuperview()
    }
}

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
    /// Every top-level key a freshly captured note may carry — `action`
    /// when the note is checked To Do at capture.
    static let allowedKeys: Set<String> = [
        "about", "format", "id", "title", "author", "created",
        "body", "links", "draft", "action", "documentType", "location",
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
                // Fetch the AI key blob at launch (the Author way), so
                // the Inspiration scan's book lookup has its key ready.
                .task { AIKeyProvider.shared.start() }
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

    /// The folder's sources, kept so a scanned book already on the
    /// shelf is cited, not doubled. The scan fills this; Inspiration
    /// appends what it mints.
    var sources: [LiquidDoc] = []

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
            // Identity first, and fast: on iOS, iCloud files stand
            // under their real names but dataless — every read blocks
            // while it downloads. A full folder can take minutes; the
            // card files, named "<id>.card.liquid.json", are spotted
            // without reading anything else and fetched alone.
            let earlyCards = Self.readCardFiles(folder: folderURL)
            await MainActor.run {
                let model = NotesModel.shared
                if !earlyCards.isEmpty {
                    model.cards = earlyCards
                    log.info("rescan: identity pass found \(earlyCards.count) card(s)")
                    if model.authorName.isEmpty, earlyCards.count == 1,
                       let card = earlyCards.first {
                        model.adopt(card: card)
                    }
                }
            }
            let result = Self.scan(folder: folderURL, author: author, cardType: cardType)
            await MainActor.run {
                // Through the singleton, not a captured self — rescan's
                // first call is inside init, before self can travel.
                let model = NotesModel.shared
                model.notes = result.notes
                model.cards = result.cards.isEmpty ? earlyCards : result.cards
                model.sources = result.sources
                log.info("rescan: \(result.notes.count) notes, \(result.cards.count) cards, \(result.sources.count) sources, \(result.pendingDownloads) downloading in \(folderURL.path)")
                // The folder is the source of identity: one card, no
                // name yet — that card is the user's, adopted without
                // asking. More than one waits for their word.
                let cards = model.cards
                if model.authorName.isEmpty, cards.count == 1,
                   let card = cards.first {
                    model.adopt(card: card)
                } else if model.authorName.isEmpty, cards.isEmpty {
                    // The card may still be on its way from iCloud —
                    // look again shortly instead of asking the user.
                    model.scheduleCardRescan()
                }
                // Files still coming from iCloud: look again as they
                // land, so the list fills in instead of stalling.
                if result.pendingDownloads > 0 {
                    model.scheduleDownloadRescan()
                }
            }
        }
    }

    /// Re-runs the scan while iCloud files are still downloading —
    /// every 3 seconds, capped, so the notes list fills in as they
    /// arrive rather than waiting on the whole folder at once.
    private var downloadRescanAttempts = 0
    private var downloadRescanTask: Task<Void, Never>?
    func scheduleDownloadRescan() {
        guard downloadRescanTask == nil, downloadRescanAttempts < 40 else { return }
        downloadRescanAttempts += 1
        downloadRescanTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            self.downloadRescanTask = nil
            self.rescan()
        }
    }

    /// The identity pass: only files named "<id>.card.liquid.json" are
    /// read — the name is visible without downloading, so who the user
    /// is arrives ahead of the whole folder.
    private nonisolated static func readCardFiles(folder folderURL: URL) -> [LiquidDoc] {
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var cards: [LiquidDoc] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.lastPathComponent.lowercased().hasSuffix(".card.liquid.json"),
                  let data = try? Data(contentsOf: url),
                  let doc = try? LiquidDoc.decode(data: data, fileURL: url),
                  doc.documentType == IdentityCard.documentType
            else { continue }
            cards.append(doc)
        }
        return cards.sorted {
            $0.author.localizedCaseInsensitiveCompare($1.author) == .orderedAscending
        }
    }

    /// Looks again for the identity card while none has landed: every
    /// two seconds, up to a minute — a fresh phone's folder is all
    /// placeholders at first, and the card is requested by name.
    private var cardRescanAttempts = 0
    private var cardRescanTask: Task<Void, Never>?
    func scheduleCardRescan() {
        guard cardRescanTask == nil, cardRescanAttempts < 30 else { return }
        cardRescanAttempts += 1
        cardRescanTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.cardRescanTask = nil
            self.rescan()
        }
    }

    /// A scan's yield: what could be read now, and whether any files
    /// are still downloading — so the caller knows to look again.
    private struct ScanResult {
        var notes: [LiquidDoc] = []
        var cards: [LiquidDoc] = []
        var sources: [LiquidDoc] = []
        var pendingDownloads = 0
    }

    private nonisolated static func scan(folder folderURL: URL, author: String,
                                         cardType: String) -> ScanResult {
        try? FileManager.default.startDownloadingUbiquitousItem(at: folderURL)
        // On iOS an iCloud document stands under its real name but may
        // be *dataless* — reading it blocks until it downloads. So the
        // scan never reads blind: it asks each file's download status,
        // reads only what is already here, and requests the rest,
        // reporting how many are still coming so the caller retries.
        let keys: [URLResourceKey] = [.isRegularFileKey,
                                      .ubiquitousItemDownloadingStatusKey]
        let enumerator = FileManager.default.enumerator(
            at: folderURL, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var result = ScanResult()
        while let url = enumerator?.nextObject() as? URL {
            guard LiquidDoc.isDocumentFile(url) else { continue }
            let status = (try? url.resourceValues(
                forKeys: [.ubiquitousItemDownloadingStatusKey]))?
                .ubiquitousItemDownloadingStatus
            // Not yet here: request it and move on — never block.
            if let status, status != .current {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                result.pendingDownloads += 1
                continue
            }
            guard let data = try? Data(contentsOf: url),
                  let doc = try? LiquidDoc.decode(data: data, fileURL: url)
            else { continue }
            if doc.documentType == cardType {
                result.cards.append(doc)
            } else if doc.documentType == LiquidDoc.DocumentType.source.rawValue {
                // The shelf, read so a scanned book is cited once.
                result.sources.append(doc)
            } else if [LiquidDoc.DocumentType.note.rawValue,
                       LiquidDoc.DocumentType.journal.rawValue,
                       LiquidDoc.DocumentType.inspiration.rawValue]
                        .contains(doc.documentType ?? ""),
                      isOwn(doc, author: author) {
                // The phone's own capture kinds — a plain note, a
                // journal entry, an inspiration — all belong in its
                // list; the shelf kinds and others' notes stay out.
                result.notes.append(doc)
            }
        }
        result.notes.sort { $0.listedDate > $1.listedDate }
        result.cards.sort {
            $0.author.localizedCaseInsensitiveCompare($1.author) == .orderedAscending
        }
        return result
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
    /// makes the empty note the editor opens on. A note checked To Do
    /// carries the standing in the file — every device lists it there —
    /// and, having a standing, is no draft.
    func createNote(title: String = "Untitled", bodyText: String = "",
                    created: Date = .now, asToDo: Bool = false,
                    kind: LiquidDoc.DocumentType = .note) -> LiquidDoc? {
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
                            // A standing or a kind of its own is a
                            // decision made — such a note is no draft.
                            draft: !asToDo && kind == .note,
                            action: asToDo ? LiquidDoc.Action.toDo.rawValue : nil,
                            documentType: kind.rawValue,
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
    func save(_ doc: LiquidDoc, title: String, bodyText: String,
              kind: String? = nil, toDo: Bool? = nil) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let body = LiquidDoc.parseBody(from: bodyText)
        // Title, body, the links the body implies, and — when the
        // editor changed it — the kind and the To Do standing are the
        // phone's to change; nothing else. Copy-and-mutate carries every
        // other field through, so a standing or attention set on the Mac
        // survives an edit made here.
        var updated = doc
        updated.title = trimmedTitle.isEmpty ? "Untitled" : trimmedTitle
        updated.body = body
        updated.links = LiquidDoc.detectedLinks(in: body)
        updated.wraps = nil
        if let kind { updated.documentType = kind }
        // The To Do toggle owns only the To Do standing: turning it on
        // marks the note To Do (and, being a decision, no longer a
        // draft); turning it off clears To Do but leaves any other
        // standing — in progress, done — the Mac may have set.
        if let toDo {
            if toDo {
                updated.action = LiquidDoc.Action.toDo.rawValue
                updated.draft = false
            } else if updated.actionValue == .toDo {
                updated.action = nil
            }
        }
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
                        // Set Up is just the shared folder now — the
                        // card adopts itself, places name themselves.
                        choosingFolder = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Choose Shared Folder")

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
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                model.openFolder(url)
                // The folder is the source of identity too: once it is
                // open, the user adopts their card or fills one in.
                Task { askForIdentityIfNeeded() }
            }
        }
        // Warm the keyboard once, after the window is up, so the first
        // note or spoken capture raises it without the launch lag.
        .task {
            try? await Task.sleep(for: .milliseconds(400))
            KeyboardPrewarmer.prewarm()
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
    /// at all. With the folder open: one card adopts itself (the scan
    /// does it), several ask which is yours, and none yet means the
    /// card is still syncing — the scan keeps looking, so no alert
    /// nags about it.
    private func askForIdentityIfNeeded() {
        guard model.folderURL != nil, model.authorName.isEmpty,
              model.cards.count > 1 else { return }
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
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                if let location = doc.location {
                                    Text(location)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            // Take the full row width so the single-line
                            // title shows as many characters as fit before
                            // it truncates, instead of wrapping.
                            .frame(maxWidth: .infinity, alignment: .leading)
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
                        // Trim the row's side padding so the title reaches
                        // closer to the screen edges — more characters per line.
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 12))
                    }
                }
            }
        }
        // Plain, edge-to-edge rows rather than inset-grouped cards, so the
        // title uses the full screen width instead of a narrow centred card.
        .listStyle(.plain)
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
        // The phone is the near end: only the last seven days show, so
        // the list stays what is at hand rather than the whole history.
        let cutoff = calendar.startOfDay(
            for: Date.now.addingTimeInterval(-7 * 24 * 60 * 60))
        var groups: [(day: Date, notes: [LiquidDoc])] = []
        for doc in model.notes where doc.listedDate >= cutoff {
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

    /// What the note is born as: a plain note, a journal entry, or an
    /// inspiration — a reference caught in the wild, which may be
    /// scanned in with the camera. Its To Do standing is a separate
    /// axis, carried by the toggle below rather than the kind.
    private enum NoteKind: String, CaseIterable {
        case note = "Note"
        case journal = "Journal"
        // "Scan" in the picker; the kind it makes is still inspiration.
        case inspiration = "Scan"
    }

    @State private var text = ""
    @State private var kind: NoteKind = .note
    /// Checked, the note is born a To Do — the standing travels in the
    /// file, so it lists under To Do on every device, just as a spoken
    /// note's To Do toggle does.
    @State private var isToDo = false
    @State private var scanning = false
    /// The progress indicator's words while a scan is being read —
    /// nil when idle.
    @State private var scanStage: String?
    /// What the scan found, awaiting the user's word: Done cites the
    /// found book; the No Source dialog offers Add as Image.
    @State private var pendingScan: ScanAnalysis?
    @FocusState private var writing: Bool

    private var foundBook: InspirationScanner.BookMatch? { pendingScan?.book }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .focused($writing)
                // The note's kind, chosen at its foot.
                Picker("Kind", selection: $kind) {
                    ForEach(NoteKind.allCases, id: \.self) { kind in
                        Text(kind.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                // Choosing Scan opens the camera straight away — one
                // tap to capture, not two.
                .onChange(of: kind) {
                    if kind == .inspiration, pendingScan == nil, scanStage == nil {
                        writing = false
                        scanning = true
                    }
                }
                // The To Do standing is its own axis — a plain note or a
                // journal entry may be a To Do. A scan is a caught
                // reference, not a task, so it offers no toggle.
                if kind != .inspiration {
                    Toggle("To Do", isOn: $isToDo)
                }
                if kind == .inspiration {
                    if let foundBook {
                        // The book, as a citation card — this is the
                        // record; Done files it on the shelf with its
                        // BibTeX and cites it. The text field above is
                        // for your own note, if any.
                        foundBookCard(foundBook)
                    } else if let pendingScan, pendingScan.book == nil {
                        // The scan found no book: the choice stands here
                        // in the sheet — a popup kept losing the race
                        // with the camera's dismissal.
                        noSourcePanel(pendingScan)
                    }
                    // The camera path: a page, a poster, a whiteboard —
                    // read on-device, placed if a book claims it, kept
                    // regardless.
                    Button {
                        scanning = true
                    } label: {
                        Label(pendingScan == nil ? "Scan" : "Scan Again",
                              systemImage: "camera.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(scanStage != nil)
                }
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save() }
                        // A found book is content in itself, so Done
                        // stands even with no typed words.
                        .disabled((text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                   && foundBook == nil)
                                  || scanStage != nil)
                }
            }
            // The scan's progress, over everything: reading, searching,
            // asking — the user always sees the machinery at work.
            .overlay {
                if let scanStage {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(scanStage)
                            .font(.callout)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        // The keyboard stands ready the moment the sheet settles. Focus
        // set during the sheet's present animation is dropped by UIKit,
        // and a single delayed try can miss a slow present — so it is
        // asserted repeatedly across the whole transition window, only
        // while nothing else (a scan) holds the view, and only until the
        // writer has the field, so a note already being typed is never
        // interrupted.
        .task {
            // Assert focus repeatedly across the present window, catching
            // the first moment the field can take it — the keyboard,
            // pre-warmed at launch, then raises at once. Stop as soon as
            // focus takes or the writer has begun, so a note already being
            // typed is never interrupted.
            for _ in 0..<14 {
                try? await Task.sleep(for: .milliseconds(120))
                guard scanStage == nil, pendingScan == nil else { continue }
                if writing || !text.isEmpty { break }
                writing = true
            }
        }
        .fullScreenCover(isPresented: $scanning) {
            CameraCapture { photo in
                scanning = false
                guard let photo else {
                    log.info("scan: camera returned no photo")
                    return
                }
                log.info("scan: photo captured, starting analysis")
                // The keyboard steps aside so the progress overlay and
                // the result panel present cleanly.
                writing = false
                // MainActor-pinned: the state these writes drive is the
                // view's own, and an unpinned Task's writes may not be
                // observed — the result panel never appeared.
                Task { @MainActor in
                    // Let the camera cover finish dismissing before the
                    // overlay presents — a state change mid-dismissal
                    // is dropped by the presentation.
                    try? await Task.sleep(for: .milliseconds(350))
                    let analysis = await model.analyzeScan(photo) { scanStage = $0 }
                    scanStage = nil
                    pendingScan = analysis
                    // A found book shows as a citation card; the text
                    // field stays the reader's own note. No book shows
                    // the inline choice below the picker.
                    log.info("scan: analysis applied, book=\(analysis.book != nil), panel should show")
                }
            }
            .ignoresSafeArea()
        }
    }

    /// The found book as a citation card — the BibTeX-style listing the
    /// scan resolved to. Done files it on the shelf and cites it.
    @ViewBuilder private func foundBookCard(_ book: InspirationScanner.BookMatch) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Book Found", systemImage: "book.closed")
                .font(.subheadline.weight(.semibold))
            Text(book.title)
                .font(.body.weight(.medium))
            if !book.authors.isEmpty {
                Text(book.authors.joined(separator: ", "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            let line = [book.publisher, book.year].compactMap { $0 }.joined(separator: " · ")
            if !line.isEmpty {
                Text(line).font(.footnote).foregroundStyle(.secondary)
            }
            if let isbn = book.isbn {
                Text("ISBN \(isbn)").font(.caption).foregroundStyle(.tertiary)
            }
            Text("Done adds it to the Library with its citation, and cites it from this note.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    /// The no-book outcome, shown in the sheet: what was read, and the
    /// two ways forward — keep it as an image note, or drop the scan.
    @ViewBuilder private func noSourcePanel(_ scan: ScanAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No Source Found", systemImage: "questionmark.circle")
                .font(.subheadline.weight(.semibold))
            // The real reason, in plain words — a refusal or a
            // rate-limit reads as itself, not a blank miss.
            Text(scan.diagnostic
                 ?? (scan.isTextFirst
                     ? "The text didn't match a book on Google Books."
                     : "The photo is mostly image."))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let guess = scan.guess {
                Text("The on-device model's guess, unverified: \(guess)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Add as Image") {
                    model.adoptScanAsImage(scan, comment: text)
                    pendingScan = nil
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                Button("Discard Scan") { pendingScan = nil }
                    .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    private func save() {
        // A scan whose book was found: file the book on the shelf with
        // its BibTeX and cite it — content in itself, so this stands
        // even with no typed words.
        if kind == .inspiration, let pendingScan, pendingScan.book != nil {
            model.adoptScanAsSource(pendingScan, comment: text)
            dismiss()
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            dismiss()
            return
        }
        let parsed = TranscriptParser.note(from: trimmed)
        // The reason for a failure is in model.lastError, shown by the
        // home view.
        switch kind {
        case .note:
            _ = model.createNote(title: parsed.title, bodyText: parsed.bodyText,
                                 asToDo: isToDo)
        case .journal:
            _ = model.createNote(title: parsed.title, bodyText: parsed.bodyText,
                                 asToDo: isToDo, kind: .journal)
        case .inspiration:
            // Saved without a scan: the words alone are the inspiration.
            _ = model.createNote(title: parsed.title, bodyText: parsed.bodyText,
                                 kind: .inspiration)
        }
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

    /// The categories an existing note can be moved between — the ones
    /// the sidebar keeps their own place for. Raw values are the
    /// documentType tokens; the Mac files a journal note under Journal
    /// when it sees the change.
    private enum EditKind: String, CaseIterable {
        case note = "note", journal = "journal", inspiration = "inspiration"
        var label: String {
            switch self {
            case .note: "Note"
            case .journal: "Journal"
            case .inspiration: "Inspiration"
            }
        }
        init(documentType: String?) {
            self = EditKind(rawValue: documentType ?? "note") ?? .note
        }
    }

    @State private var title = ""
    @State private var bodyText = ""
    @State private var kind: EditKind = .note
    /// The note's To Do standing, editable here the same way the new
    /// note and the spoken note offer it. It is a separate axis from
    /// the category, so it rides its own toggle.
    @State private var isToDo = false
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
                    // The note's category, changeable while editing —
                    // choosing Journal here files it under Journal on
                    // the Mac.
                    if isEditing {
                        Picker("Category", selection: $kind) {
                            ForEach(EditKind.allCases, id: \.self) { kind in
                                Text(kind.label)
                            }
                        }
                        .pickerStyle(.segmented)
                        Toggle("To Do", isOn: $isToDo)
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
            kind = EditKind(documentType: doc.documentType)
            isToDo = doc.actionValue == .toDo
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
        model.save(doc, title: savedTitle, bodyText: bodyText,
                   kind: kind.rawValue, toDo: isToDo)
    }
}
