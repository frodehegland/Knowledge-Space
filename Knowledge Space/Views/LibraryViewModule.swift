import SwiftUI

/// One place in the sidebar: the document library, or an installed view
/// module by id. Views appear as `.view(id)`.
enum SidebarItem: Hashable {
    case library      // the Inbox: what is new and unread
    case timeline     // every note, by time, latest on top
    case place        // the same notes, grouped by country and town
    case people       // the same notes, grouped by author
    case filedFolder(String)  // one filing folder, straight from the sidebar
    case view(String)

    /// Origami Text's name for the reading context; view modules written
    /// there land in the same place here.
    static var allDocuments: SidebarItem { .timeline }
}

/// One place in the sidebar: a named, iconed destination.
struct SidebarPlace: Identifiable {
    let name: String
    let systemImage: String
    let item: SidebarItem
    var id: SidebarItem { item }
}

enum SidebarCatalog {
    /// The light grey every sidebar icon wears — place rows and action
    /// rows alike, so the column reads as one set.
    static let iconTint = Color(white: 0.75)

    /// The head of the column: the Inbox stands alone above the Library
    /// heading, with New Note (added by the sidebar view) under it.
    static let top: [SidebarPlace] = [
        SidebarPlace(name: "Inbox", systemImage: "tray", item: .library),
    ]

    static let library: [SidebarPlace] = [
        SidebarPlace(name: "Timeline", systemImage: "clock", item: .timeline),
        SidebarPlace(name: "Places", systemImage: "mappin.and.ellipse", item: .place),
        // The Map view module, seated in the Library under Places
        // rather than with the other views.
        SidebarPlace(name: "Map", systemImage: "map", item: .view("places")),
        SidebarPlace(name: "People", systemImage: "person.2", item: .people),
    ]

    /// The note column's fixed offering, in its order — the Action run,
    /// then the standard files, each button's word beside the folder it
    /// files under. The sidebar's Filed section mirrors the same list.
    static let actionFolders = ["To Do", "In Progress", "Done"]
    static let standardFiles: [(label: String, folder: String)] =
        [("Thought", "Thoughts"), ("Journal", "Journal"), ("Note", "Notes")]

    /// The installed views — minus any module the Library section
    /// already seats (the Map lives under Places).
    static var views: [SidebarPlace] {
        let seated = Set(library.map(\.item))
        return LibraryViewRegistry.modules
            .filter { !seated.contains(.view($0.id)) }
            .map { SidebarPlace(name: $0.name, systemImage: $0.systemImage, item: .view($0.id)) }
    }

    /// Filed is a heading, not a click: each folder in use stands as
    /// its own place, one click from its contents.
    static func filed(_ folders: [String]) -> [SidebarPlace] {
        folders.map {
            SidebarPlace(name: $0,
                         systemImage: filedIcon(for: $0),
                         item: .filedFolder($0))
        }
    }

    private static func filedIcon(for folder: String) -> String {
        switch folder {
        case "To Do": return "checklist"
        case "In Progress": return "clock"
        case "Done": return "checkmark.circle"
        case "Thoughts": return "lightbulb"
        case "Journal": return "book.closed"
        case "Notes": return "note.text"
        case AppState.archivedFolderName: return "archivebox"
        default: return "folder"
        }
    }

    static func sections(filedFolders: [String]) -> [(title: String, places: [SidebarPlace])] {
        [("", top), ("Library", library), ("Filed", filed(filedFolders)), ("Views", views)]
    }
}

/// UserDefaults keys the view modules read their tunable prompts from,
/// mirroring Origami Text's AppSettings so modules travel unchanged.
enum AppSettings {
    static let aiInsightsPromptKey = "aiInsightsPrompt"
    static let aiThemesPromptKey = "aiThemesPrompt"
    static let aiOpenQuestionsPromptKey = "aiOpenQuestionsPrompt"
    static let aiDisagreementsPromptKey = "aiDisagreementsPrompt"
    static let aiAgreementsPromptKey = "aiAgreementsPrompt"
    static let aiStrangerChallengePromptKey = "aiStrangerChallengePrompt"
    static let aiStrangerSupportPromptKey = "aiStrangerSupportPrompt"
    // The portrait pipeline's settings, shared with Digital Letters.
    static let portraitStyleKey = "portraitStyle"
    static let portraitPromptKey = "portraitPrompt"
    static let portraitInstantProcessingKey = "portraitInstantProcessing"
}

/// Origami Text's transcript test, kept under the same name so modules
/// that ask "is this a transcript?" compile unchanged. The full
/// TranscriptsView remains in Origami Text; only the judgement travels.
enum TranscriptsView {
    /// A transcript is a document declared `transcript`, or — for documents
    /// imported before the type existed — one whose body carries at least
    /// two distinct speaker attributions.
    static func isTranscript(_ doc: LiquidDoc) -> Bool {
        if doc.documentType == LiquidDoc.DocumentType.transcript.rawValue { return true }
        return Set((doc.body ?? []).compactMap(\.speaker)).count >= 2
    }
}

/// One way of seeing the library, packaged for exchange.
///
/// Views are modules so community members can write and share them as
/// single Swift files. To create one:
///
///  1. Write a SwiftUI view (or two) in one file. Read library data from
///     the environment model — `@Environment(AppModel.self) private var
///     model` — e.g. `model.index.byID`, `model.index.backlinks`, or the
///     derivations in LibraryInsights. Navigate with
///     `model.openInLibrary(doc)`, `model.open(doc, fragment:)`, or
///     `model.openTranspointing(from:to:)`.
///  2. At the bottom of the file, expose a `LibraryViewModule` describing
///     it: a stable id, sidebar name, SF Symbol, and how to build its panes.
///  3. Add that module to `LibraryViewRegistry.modules` — one line.
///
/// The sidebar entry, selection, and routing then work automatically.
@MainActor
struct LibraryViewModule: Identifiable {
    /// Stable identifier, lowercase and hyphenated, e.g. "hot-paragraphs".
    let id: String
    /// Sidebar label.
    let name: String
    /// Sidebar SF Symbol name.
    let systemImage: String
    /// The content column (middle pane) while this view is selected.
    let makeContent: () -> AnyView
    /// The detail pane, or nil to leave the standard reader in charge.
    /// The closure may also return nil to fall back conditionally.
    var makeDetail: ((AppModel) -> AnyView?)? = nil
    /// Whole-library views (the Weave, Connections, the AI reports) set
    /// this so the document list column steps aside while they are active:
    /// the view already speaks for every document.
    var hidesDocumentList = false
}

/// The installed views, in sidebar order.
@MainActor
enum LibraryViewRegistry {
    static let modules: [LibraryViewModule] = [
        DocumentWebView.module,
        WeaveView.module,
        AuthorsCircleView.module,
        PlacesView.module,
        AttentionsView.module,
        StrangerView.module,
        TrailsView.module,
        GeometriesView.module,
        GlossaryView.module,
        GlossarySpaceView.module,
        KNavView.module,
        HotParagraphsView.module,
        AIInsightsView.module,
        ThemesView.module,
        OpenQuestionsView.module,
        AgreementsView.module,
        DisagreementsView.module,
        TheDealView.module,
        ZView.module,
        ZigZagView.module,
        ZZNavigatorView.module,
        HealthDashboardView.module,
    ]

    static func module(id: String) -> LibraryViewModule? {
        modules.first { $0.id == id }
    }

    static func module(for item: SidebarItem?) -> LibraryViewModule? {
        guard case .view(let id)? = item else { return nil }
        return module(id: id)
    }
}

/// The library's document list, as the content column: what the modules'
/// `makeContent` shows when a view keeps the standard list beside itself.
/// The sidebar chooses the grouping: Timeline reads it by day (Today,
/// Yesterday, the days before), Place by country with the town on each
/// row.
struct DocumentListView: View {
    @Environment(AppState.self) private var state
    var grouping: Grouping = .time
    /// Narrows the list to notes filed under one folder — the sidebar's
    /// To Do place is this list scoped to the "To Do" folder.
    var filedUnder: String? = nil
    /// The Inbox keeps to the reader's own notes plus anything unread;
    /// a read document steps aside once opened.
    var inboxOnly = false

    enum Grouping {
        case time, place
    }

    /// The entries this list speaks for: the Inbox's, one folder's, or
    /// everything.
    private var scopedEntries: [IndexEntry] {
        if let filedUnder {
            // A folder's list reads straight from the filings, so it
            // shows every note filed there — however the library lists
            // treat the note otherwise.
            return state.filedFolders
                .filter { $0.value.caseInsensitiveCompare(filedUnder) == .orderedSame }
                .compactMap { state.index.allByID[$0.key] }
                .sorted { $0.doc.listedDate > $1.doc.listedDate }
        }
        guard inboxOnly else { return state.filteredEntries }
        // The Inbox is only what is new and unread — a filed note has
        // moved on to its folder, and the standing To Do and Done notes
        // keep to their own sidebar places.
        return state.filteredEntries.filter { entry in
            (entry.doc.documentType == LiquidDoc.DocumentType.note.rawValue
                || state.isUnread(entry.doc))
                && state.folder(for: entry.doc) == nil
                && !Self.pinnedTitles.contains {
                    entry.doc.title.trimmingCharacters(in: .whitespaces)
                        .caseInsensitiveCompare($0) == .orderedSame
                }
        }
    }

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 0) {
            List(selection: $state.selectedDocID) {
                // A bare place the search has placed awaits the reader's
                // word before it groups under that country.
                if grouping == .place, !state.places.pendingVerification.isEmpty {
                    Section("Confirm Places") {
                        ForEach(state.places.pendingVerification) { record in
                            placeVerificationRow(record)
                        }
                    }
                }
                // The standing notes, above every grouping.
                if !pinnedEntries.isEmpty {
                    Section {
                        ForEach(pinnedEntries) { entry in
                            DocumentRow(entry: entry)
                                .tag(entry.id)
                                .listRowSeparator(.hidden)
                        }
                    }
                }
                ForEach(groups, id: \.label) { group in
                    Section(group.label) {
                        ForEach(group.entries) { entry in
                            DocumentRow(entry: entry, detail: detail(for: entry.doc))
                                .tag(entry.id)
                                .listRowSeparator(.hidden)
                                // A folder's rows keep the Filed list's
                                // put-it-back.
                                .contextMenu {
                                    if filedUnder != nil {
                                        Button("Unfile") { state.unfile(entry.doc) }
                                    }
                                }
                        }
                    }
                }
                if state.index.isScanning {
                    Label("Scanning…", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                }

                // Malformed files never crash the app: they surface greyed
                // out with a reason, and stay out of the index.
                if !state.index.unreadableFiles.isEmpty {
                    Section("Unreadable Files") {
                        ForEach(state.index.unreadableFiles) { file in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.fileURL.lastPathComponent)
                                Text(file.reason)
                                    .font(.caption)
                            }
                            .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .overlay {
                if state.index.folderURL != nil, scopedEntries.isEmpty,
                   !state.index.isScanning {
                    if let filedUnder {
                        ContentUnavailableView(
                            "Nothing Here",
                            systemImage: "checklist",
                            description: Text("File a note under \(filedUnder) — from the column beside the reader — and it lists here."))
                    } else {
                        ContentUnavailableView("Empty Library",
                                               systemImage: "tray",
                                               description: Text("No .liquid.json documents in the folder yet."))
                    }
                }
            }
        }
        // Every location the library holds gets its one search, so bare
        // places can be confirmed and the map can stand its pins.
        .task(id: state.index.timeline.count) {
            state.places.resolveMissing(in: state.filteredEntries.map(\.doc.location))
        }
    }

    private func placeVerificationRow(_ record: PlaceDirectory.Record) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(record.place)
                .font(.subheadline.weight(.semibold))
            Text("Found in \(record.country ?? "an unknown country"). Group it there?")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Confirm") { state.places.verify(record) }
                Button("Not This") { state.places.reject(record) }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    // MARK: The standing notes

    /// "To Do" and "Done" stand at the top of the list, above the
    /// groupings; see AppState.ensureStandingNotes().
    static let pinnedTitles = ["To Do", "Done"]

    private var pinnedEntries: [IndexEntry] {
        // The standing notes head the whole library, not a folder's
        // slice or the Inbox.
        guard filedUnder == nil, !inboxOnly else { return [] }
        return Self.pinnedTitles.compactMap { title in
            state.filteredEntries.first {
                $0.doc.title.trimmingCharacters(in: .whitespaces)
                    .caseInsensitiveCompare(title) == .orderedSame
            }
        }
    }

    // MARK: Grouping

    private var groups: [(label: String, entries: [IndexEntry])] {
        let pinnedIDs = Set(pinnedEntries.map(\.id))
        let entries = scopedEntries.filter { !pinnedIDs.contains($0.id) }
        switch grouping {
        case .place: return placeGroups(entries)
        case .time: return timeGroups(entries)
        }
    }

    /// Newest first, one section per day, spoken relatively where the
    /// day is near: Today, Yesterday, then the day itself — the year
    /// joining once the day is not this year's.
    private func timeGroups(_ entries: [IndexEntry]) -> [(label: String, entries: [IndexEntry])] {
        var groups: [(label: String, entries: [IndexEntry])] = []
        for entry in entries {
            let label = dayLabel(for: entry.doc)
            if groups.last?.label == label {
                groups[groups.count - 1].entries.append(entry)
            } else {
                groups.append((label: label, entries: [entry]))
            }
        }
        return groups
    }

    private func dayLabel(for doc: LiquidDoc) -> String {
        // A human-assigned date without a day keeps its own precision.
        if let date = doc.date, date.day == nil {
            return date.monthYearText
        }
        let day = doc.listedDate
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        if calendar.isDate(day, equalTo: .now, toGranularity: .year) {
            return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
        }
        return day.formatted(.dateTime.day().month(.wide).year())
    }

    /// One section per country (the location's last part, per the
    /// format's place convention), the town on the row; notes that
    /// carried no place gather at the end.
    private func placeGroups(_ entries: [IndexEntry]) -> [(label: String, entries: [IndexEntry])] {
        var byCountry: [String: [IndexEntry]] = [:]
        var placeless: [IndexEntry] = []
        for entry in entries {
            if let country = country(of: entry.doc) {
                byCountry[country, default: []].append(entry)
            } else {
                placeless.append(entry)
            }
        }
        var groups = byCountry.keys.sorted().map { (label: $0, entries: byCountry[$0]!) }
        if !placeless.isEmpty {
            groups.append((label: "Unspecified", entries: placeless))
        }
        return groups
    }

    /// Under Time the section heading says it all; under Place the town
    /// rides on the row.
    private func detail(for doc: LiquidDoc) -> String? {
        grouping == .place ? town(of: doc) : nil
    }

    /// "Wimbledon, London, United Kingdom" → "United Kingdom". A bare
    /// place like "Ytrebygda" answers only once its one-time search has
    /// been confirmed by the reader.
    private func country(of doc: LiquidDoc) -> String? {
        guard let location = doc.location else { return nil }
        let parts = location.split(separator: ",")
        if parts.count >= 2 {
            let country = parts.last!.trimmingCharacters(in: .whitespaces)
            return country.isEmpty ? nil : country
        }
        return state.places.verifiedCountry(for: location)
    }

    /// "Wimbledon, London, United Kingdom" → "Wimbledon, London"; a bare
    /// confirmed place stands as its own town. An address the reader
    /// defined in Settings ▸ Locations shows as Home or Work instead.
    private func town(of doc: LiquidDoc) -> String? {
        if let label = AppLocations.label(for: doc.location) { return label }
        guard let location = doc.location else { return nil }
        let parts = location.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if parts.count >= 2 {
            return parts.dropLast().joined(separator: ", ")
        }
        return state.places.verifiedCountry(for: location) != nil ? location : nil
    }
}

/// The People place: everyone whose identity card lives in the shared
/// folder — the contact records shared with Digital Letters through
/// People.json, joined by any identity card the phone wrote. Clicking a
/// person fills the next column with the notes naming them; the reveal
/// triangle unfolds their contact information in place. Ctrl-click a
/// person to edit their record.
struct PeopleListView: View {
    @Environment(AppState.self) private var state
    /// The record being edited, presented as the person form.
    @State private var editingListing: PersonListing?

    /// The listings, alphabetical from AppState, narrowed by the search
    /// field on name, alias, or affiliation.
    private var people: [PersonListing] {
        guard !state.searchText.isEmpty else { return state.peopleListings }
        return state.peopleListings.filter { listing in
            listing.person.displayName.localizedCaseInsensitiveContains(state.searchText)
                || listing.person.affiliation.localizedCaseInsensitiveContains(state.searchText)
                || (listing.person.aliases ?? []).contains {
                    $0.localizedCaseInsensitiveContains(state.searchText)
                }
        }
    }

    /// Selecting a person also puts down any open document, so their
    /// mentions take the reading column.
    private var selection: Binding<String?> {
        Binding(
            get: { state.selectedPersonID },
            set: { id in
                state.selectedPersonID = id
                if id != nil { state.selectedDocID = nil }
            }
        )
    }

    var body: some View {
        List(selection: selection) {
            ForEach(people) { listing in
                // The reveal triangle unfolds the person's contact
                // details in place; clicking the person fills the next
                // column with the notes that name them.
                DisclosureGroup {
                    contactDetails(listing.person)
                } label: {
                    personRow(listing)
                }
                .tag(listing.id)
                .listRowSeparator(.hidden)
                #if os(macOS)
                .contextMenu {
                    Button("Edit Person…") {
                        editingListing = listing
                    }
                }
                #endif
            }
        }
        .overlay {
            if people.isEmpty, state.index.folderURL != nil,
               !state.index.isScanning {
                ContentUnavailableView(
                    "No People",
                    systemImage: "person.2",
                    description: Text("People appear here from the shared folder's contact records — Digital Letters' People.json and the phone's identity cards. Ctrl-click People in the sidebar to add someone."))
            }
        }
        #if os(macOS)
        .sheet(item: $editingListing) { listing in
            PersonFormView(person: listing.person, heading: "Edit Person") { updated in
                state.people.upsert(updated)
                state.publishPortraits()
                state.index.rescan()
            }
        }
        #endif
    }

    /// The record's lines, unfolded under the name.
    @ViewBuilder private func contactDetails(_ person: Person) -> some View {
        let details: [(String, String)] = [
            ("ORCID", person.orcid),
            ("Affiliation", person.affiliation),
            ("Email", person.emails.joined(separator: ", ")),
            ("Aliases", (person.aliases ?? []).joined(separator: ", ")),
            ("Profile", person.publicProfile ?? ""),
        ].filter { !$0.1.isEmpty }
        if details.isEmpty {
            Text("The record carries only the name.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            ForEach(details, id: \.0) { label, value in
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(value)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func personRow(_ listing: PersonListing) -> some View {
        let mentionCount = state.index.mentions[listing.id]?.count ?? 0
        return HStack(spacing: 10) {
            PersonAvatarView(name: listing.person.displayName, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(listing.person.displayName)
                if !listing.person.affiliation.isEmpty {
                    Text(listing.person.affiliation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if mentionCount > 0 {
                Spacer(minLength: 6)
                Text("\(mentionCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(.vertical, 2)
    }
}

/// One row of the People place: a contact record from the directory, or
/// an identity card the directory does not answer for. The id keys the
/// index's mention map.
struct PersonListing: Identifiable {
    let id: String
    let person: Person
    /// Set when the row stands on an identity card document alone.
    let cardDocID: String?
}

/// A person's page in the reading column: the notes that name them,
/// newest first, under their face and name. Clicking a note opens it
/// in this column's place; the contact details stay with the People
/// list, under the reveal triangle.
struct PersonMentionsView: View {
    @Environment(AppState.self) private var state
    let listing: PersonListing

    private var mentions: [IndexEntry] {
        (state.index.mentions[listing.id] ?? []).compactMap { state.index.byID[$0] }
    }

    var body: some View {
        List {
            HStack(spacing: 12) {
                PersonAvatarView(name: listing.person.displayName, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(listing.person.displayName)
                        .font(.title3.weight(.semibold))
                    if !listing.person.affiliation.isEmpty {
                        Text(listing.person.affiliation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 6)
            .listRowSeparator(.hidden)
            Section("Mentioned In") {
                ForEach(mentions) { entry in
                    Button {
                        state.open(entry.doc)
                    } label: {
                        DocumentRow(entry: entry)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                }
            }
        }
        .overlay {
            if mentions.isEmpty {
                ContentUnavailableView(
                    "No Mentions",
                    systemImage: "person.2",
                    description: Text("No note names \(listing.person.displayName) yet — by their name or an alias from their record."))
            }
        }
    }
}

