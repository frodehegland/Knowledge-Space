import SwiftUI

/// The view modules were written against Origami Text's `AppModel`; in
/// Knowledge Space the same role is played by `AppState`. The alias lets
/// module files travel between the two apps unchanged.
typealias AppModel = AppState

/// The library API the view modules stand on: navigation, filtering,
/// insights, and parallel reading. Everything here works from the document
/// index alone — no letters, drafts, or bots.
extension AppState {

    // MARK: - Navigation

    /// What the reader is showing: the document and the paragraph it
    /// arrived at, mirroring Origami Text's navigation destination.
    struct Destination: Hashable {
        let doc: LiquidDoc
        let fragment: String?
    }

    var current: Destination? {
        selectedDoc.map { Destination(doc: $0, fragment: pendingFragment) }
    }

    func open(_ doc: LiquidDoc, fragment: String? = nil, span: String? = nil) {
        exitParallel()
        selectedDocID = doc.id
        // Paragraph ids are only trustworthy in the document they were
        // written against.
        pendingFragment = fragment
    }

    /// Opens a document in the reading context (the Documents list), used
    /// by insight views whose rows lead to a document.
    func openInLibrary(_ doc: LiquidDoc, fragment: String? = nil) {
        sidebarSelection = .library
        open(doc, fragment: fragment)
    }

    /// `origamitext://` links from inside view modules route through the
    /// same resolution as the reader's.
    func handleURL(_ url: URL) {
        open(url: url)
    }

    /// Resolves a document by id. Origami Text also checks its drafts and
    /// published shelves; here the community index is the whole library.
    func document(for id: String) -> LiquidDoc? {
        index.byID[id]?.doc
    }

    func title(for id: String) -> String? {
        document(for: id)?.title
    }

    // MARK: - Parallel reading (transpointing)

    /// Documents connected to the current one, offered for parallel reading.
    var parallelCandidates: [IndexEntry] {
        guard let doc = selectedDoc else { return [] }
        return ParallelReading.candidates(for: doc, byID: index.byID, backlinks: index.backlinks)
    }

    /// Opens a pair side by side directly (used by the Connections web).
    func openTranspointing(from: LiquidDoc, to: LiquidDoc) {
        open(from)
        enterParallel(with: to)
    }

    // MARK: - Identity

    /// The reader's name, as documents credit it. Views use it to tell
    /// "mine" from "theirs"; it is also matched against attention lists.
    var authorName: String {
        get {
            let stored = UserDefaults.standard.string(forKey: "authorName") ?? ""
            #if os(macOS)
            return stored.isEmpty ? NSFullUserName() : stored
            #else
            return stored
            #endif
        }
        set { UserDefaults.standard.set(newValue, forKey: "authorName") }
    }

    /// The identity folded into Visual-Meta on export — filled from the
    /// user's card when the folder holds one.
    var authorIdentity: AuthorIdentity {
        let card = ownCard.map(IdentityCard.init(doc:)) ?? IdentityCard()
        return AuthorIdentity(name: authorName,
                              personalTitle: card.personalTitle,
                              orcid: card.orcid,
                              affiliation: card.affiliation)
    }

    /// Every identity card in the community folder — each an ordinary
    /// Origami document (`documentType: "card"`) carrying one person's
    /// public record, the same cards the phone reads and writes.
    var cards: [LiquidDoc] {
        index.timeline.map(\.doc)
            .filter { $0.documentType == IdentityCard.documentType }
            .sorted { $0.author.localizedCaseInsensitiveCompare($1.author) == .orderedAscending }
    }

    /// Deleting a person removes their record and portrait; this trashes
    /// their identity-card document too — the card the row was built
    /// from, and any card whose author answers to them — so they do not
    /// return from the folder on the next scan. The caller rescans.
    @discardableResult
    func deleteIdentityCards(for listing: PersonListing) -> Int {
        let targets = cards.filter { card in
            card.id == listing.cardDocID || listing.person.answersTo(card.author)
        }
        for card in targets {
            try? FileManager.default.trashItem(at: card.fileURL, resultingItemURL: nil)
        }
        return targets.count
    }

    /// The People place's rows: every contact record in the directory
    /// (People.json, shared with Digital Letters), then every identity
    /// card the directory does not answer for — so a person is one row
    /// however their record arrived. The row id matches the mention
    /// map's key: the record's id, or the card document's.
    var peopleListings: [PersonListing] {
        var listings = people.people
            .filter { !$0.displayName.isEmpty }
            .map { PersonListing(id: $0.id, person: $0, cardDocID: nil) }
        for cardDoc in cards where people.person(named: cardDoc.author) == nil {
            let card = IdentityCard(doc: cardDoc)
            var person = Person(displayName: cardDoc.author)
            person.affiliation = card.affiliation
            person.orcid = card.orcid
            person.aliases = card.aliases.isEmpty ? nil : card.aliases
            listings.append(PersonListing(id: cardDoc.id, person: person,
                                          cardDocID: cardDoc.id))
        }
        return listings.sorted {
            $0.person.displayName
                .localizedCaseInsensitiveCompare($1.person.displayName) == .orderedAscending
        }
    }

    var selectedPersonListing: PersonListing? {
        guard let selectedPersonID else { return nil }
        return peopleListings.first { $0.id == selectedPersonID }
    }

    /// The user's own card in the folder, when one carries their name.
    var ownCard: LiquidDoc? {
        let name = authorName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return cards.first {
            $0.author.trimmingCharacters(in: .whitespaces)
                .caseInsensitiveCompare(name) == .orderedSame
        }
    }

    /// "This card is mine" — identity adopted from the folder's shared
    /// record, never typed in as a bare name.
    func adopt(card doc: LiquidDoc) {
        authorName = doc.author
    }

    /// The user's public identity, written into the community folder as
    /// an ordinary Origami document — the same card the phone writes.
    /// Rewrites the existing card in place when one exists; otherwise a
    /// new card joins the folder beside the documents. A picked
    /// photograph is processed (square, small JPEG) into the folder as
    /// `<card-id>.photo.jpg` and named on the card's "Photo:" line.
    func saveCard(_ card: IdentityCard, photoData: Data? = nil) {
        guard let folderURL = index.folderURL else {
            showNote("Choose a library folder first — the card lives there.")
            return
        }
        let name = card.displayName
        guard !name.isEmpty else {
            showNote("A card needs at least a name.")
            return
        }
        let existing = ownCard
        let created = existing?.created ?? .now
        let id = existing?.id ?? LiquidAddress.makeID(author: name, created: created) { candidate in
            self.index.isIDTaken(candidate)
        }
        var card = card
        if let photoData, let processed = CardPhoto.processed(from: photoData) {
            let photoName = IdentityCard.photoFileName(forCardID: id)
            do {
                try processed.write(to: folderURL.appendingPathComponent(photoName),
                                    options: .atomic)
                card.photoFileName = photoName
            } catch {
                showNote("Could not write the photo: \(error.localizedDescription)")
            }
        } else if card.photoFileName.isEmpty, let existing,
                  let oldPhoto = IdentityCard(doc: existing).photoURL(in: folderURL) {
            // The photo was removed from the card — its file goes too.
            try? FileManager.default.removeItem(at: oldPhoto)
        }
        // The card travels under a name a fresh device can spot among
        // iCloud placeholders — "<id>.card.liquid.json" — so a phone
        // just given the folder downloads identity first and adopts it
        // without asking. The same JSON either way; only the name says
        // what it is before the bytes arrive.
        let cardURL = Self.cardFileURL(id: id, in: folderURL)
        let doc = LiquidDoc(format: LiquidDoc.knownFormat,
                            id: id,
                            title: name,
                            author: name,
                            created: created,
                            body: LiquidDoc.parseBody(from: card.bodyText),
                            links: [],
                            wraps: nil,
                            documentType: IdentityCard.documentType,
                            fileURL: cardURL)
        do {
            try doc.jsonData().write(to: doc.fileURL, options: .atomic)
        } catch {
            showNote("Could not write your card: \(error.localizedDescription)")
            return
        }
        // A card saved before the naming convention moves to it.
        if let existing, existing.fileURL != cardURL {
            try? FileManager.default.removeItem(at: existing.fileURL)
        }
        authorName = name
        index.rescan()
    }

    /// Where a card lives: named so the file declares itself a card.
    static func cardFileURL(id: String, in folder: URL) -> URL {
        folder.appendingPathComponent("\(id).card")
            .appendingPathExtension(LiquidDoc.fileExtension)
    }

    /// A note the phone marked `journal` files itself under Journal —
    /// the kind travels in the document, the filing stays this Mac's.
    /// Called after each scan; already-filed notes are left alone.
    func fileJournalNotes() {
        for entry in index.timeline
        where entry.doc.documentType == LiquidDoc.DocumentType.journal.rawValue
            && folder(for: entry.doc) == nil {
            fileDocument(entry.doc, under: "Journal")
        }
    }

    /// Cards written before the "<id>.card.liquid.json" convention take
    /// the new name quietly, so every device can spot them unread.
    /// Called after each scan; does nothing once the names are right.
    func tidyCardFileNames() {
        guard let folderURL = index.folderURL else { return }
        for cardDoc in cards {
            let wanted = Self.cardFileURL(id: cardDoc.id, in: folderURL)
            guard cardDoc.fileURL != wanted,
                  !cardDoc.fileURL.lastPathComponent.contains(".card.") else { continue }
            try? FileManager.default.moveItem(at: cardDoc.fileURL, to: wanted)
        }
    }

    // MARK: - List filtering

    /// The listed entries, narrowed by the search field.
    var filteredEntries: [IndexEntry] {
        guard !searchText.isEmpty else { return listedEntries }
        return listedEntries.filter { matches($0.doc) }
    }

    private func matches(_ doc: LiquidDoc) -> Bool {
        doc.title.localizedCaseInsensitiveContains(searchText)
            || doc.author.localizedCaseInsensitiveContains(searchText)
            || doc.onBehalfOf?.localizedCaseInsensitiveContains(searchText) == true
            || (doc.body ?? []).contains { $0.text.localizedCaseInsensitiveContains(searchText) }
    }

    /// Everything addressed for the user's attention.
    var attentionEntries: [IndexEntry] {
        filteredEntries.filter { entry in
            entry.doc.attention.contains { authorIdentity.matches(author: $0) }
        }
    }

    // MARK: - Library insights

    var hotParagraphs: [HotParagraph] {
        var paragraphs = LibraryInsights.hotParagraphs(byID: index.byID, backlinks: index.backlinks)
        if !searchText.isEmpty {
            paragraphs = paragraphs.filter {
                $0.paragraph.text.localizedCaseInsensitiveContains(searchText)
                    || $0.doc.title.localizedCaseInsensitiveContains(searchText)
                    || $0.doc.author.localizedCaseInsensitiveContains(searchText)
            }
        }
        return paragraphs
    }

    var healthReport: HealthReport {
        LibraryInsights.healthReport(byID: index.byID,
                                     backlinks: index.backlinks,
                                     unreadable: index.unreadableFiles,
                                     superseded: index.supersededIDs)
    }

    // MARK: - Views on show

    func isViewHidden(_ id: String) -> Bool {
        hiddenViewIDs.contains(id)
    }

    /// A section's sidebar places, minus the views switched off.
    func shownPlaces(of places: [SidebarPlace]) -> [SidebarPlace] {
        places.filter { place in
            if case .view(let id) = place.item { return !isViewHidden(id) }
            return true
        }
    }

    /// The last places notes carried, newest first and each once —
    /// offered in Settings ▸ Locations so Home and Work are picked from
    /// where the notes have actually been, not typed.
    var recentLocations: [String] {
        var seen: [String] = []
        for entry in index.timeline.reversed() {
            guard let location = entry.doc.location else { continue }
            if !seen.contains(where: { $0.caseInsensitiveCompare(location) == .orderedSame }) {
                seen.append(location)
            }
            if seen.count == 10 { break }
        }
        return seen
    }
}

/// Home, Work, and aliases as the reader defined them in Settings ▸
/// Locations. A note always stores the full place name it was captured
/// with; only the display substitutes the label. A private reading
/// preference, like muting — never written into any document.
nonisolated enum AppLocations {
    static let homeKey = "homeLocation"
    static let workKey = "workLocation"
    static let aliasesKey = "locationAliases"

    /// The label when one applies — "Home", "Work", or an alias — else
    /// nil.
    static func label(for location: String?) -> String? {
        guard let location else { return nil }
        let trimmed = location.trimmingCharacters(in: .whitespaces)
        if matches(trimmed, UserDefaults.standard.string(forKey: homeKey)) { return "Home" }
        if matches(trimmed, UserDefaults.standard.string(forKey: workKey)) { return "Work" }
        return alias(for: trimmed)
    }

    // MARK: Aliases

    /// Every alias: the full stored place name → the name displayed for
    /// it. Made by editing a location's text in the options column;
    /// edited or removed in Settings ▸ Locations.
    static var aliases: [String: String] {
        UserDefaults.standard.dictionary(forKey: aliasesKey) as? [String: String] ?? [:]
    }

    static func alias(for location: String) -> String? {
        let trimmed = location.trimmingCharacters(in: .whitespaces)
        return aliases.first {
            $0.key.caseInsensitiveCompare(trimmed) == .orderedSame
        }?.value
    }

    /// Sets, replaces, or (with nil or empty) removes the alias for a
    /// stored place name.
    static func setAlias(_ alias: String?, for location: String) {
        var all = aliases
        let trimmed = location.trimmingCharacters(in: .whitespaces)
        if let existing = all.keys.first(where: {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            all.removeValue(forKey: existing)
        }
        if let alias = alias?.trimmingCharacters(in: .whitespaces), !alias.isEmpty {
            all[trimmed] = alias
        }
        UserDefaults.standard.set(all, forKey: aliasesKey)
    }

    /// The location as displayed: the label when one applies, otherwise
    /// the full place name itself.
    static func display(_ location: String?) -> String? {
        label(for: location) ?? location
    }

    private static func matches(_ location: String, _ defined: String?) -> Bool {
        guard let defined = defined?.trimmingCharacters(in: .whitespaces),
              !defined.isEmpty else { return false }
        return defined.caseInsensitiveCompare(location) == .orderedSame
    }
}
