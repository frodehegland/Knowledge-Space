import SwiftUI

/// One place in the sidebar: the document library, or an installed view
/// module by id. Views appear as `.view(id)`.
enum SidebarItem: Hashable {
    case library      // the Inbox: notes, plus anything unread, by day
    case place        // the same notes, grouped by country and town
    case toDo         // notes marked To Do (filed under the To Do folder)
    case drafts       // notes still on the desk, out of the Inbox and views
    case filedFolder(String)  // one filing folder, straight from the sidebar
    case view(String)

    /// Origami Text's name for the reading context; view modules written
    /// there land in the same place here.
    static var allDocuments: SidebarItem { .library }
}

/// One place in the sidebar: a named, iconed destination.
struct SidebarPlace: Identifiable {
    let name: String
    let systemImage: String
    let item: SidebarItem
    var id: SidebarItem { item }
}

enum SidebarCatalog {
    static let library: [SidebarPlace] = [
        SidebarPlace(name: "Inbox", systemImage: "tray", item: .library),
        SidebarPlace(name: "Place", systemImage: "mappin.and.ellipse", item: .place),
        SidebarPlace(name: "To Do", systemImage: "checklist", item: .toDo),
        SidebarPlace(name: "Drafts", systemImage: "pencil.line", item: .drafts),
    ]

    static var views: [SidebarPlace] {
        LibraryViewRegistry.modules.map {
            SidebarPlace(name: $0.name, systemImage: $0.systemImage, item: .view($0.id))
        }
    }

    /// Filed is a heading, not a click: each folder in use stands as
    /// its own place, one click from its contents.
    static func filed(_ folders: [String]) -> [SidebarPlace] {
        folders.map {
            SidebarPlace(name: $0,
                         systemImage: $0 == AppState.archivedFolderName
                             ? "archivebox" : "folder",
                         item: .filedFolder($0))
        }
    }

    static func sections(filedFolders: [String]) -> [(title: String, places: [SidebarPlace])] {
        var sections = [("Library", library)]
        if !filedFolders.isEmpty {
            sections.append(("Filed", filed(filedFolders)))
        }
        sections.append(("Views", views))
        return sections
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
    /// The Drafts list: notes still on the desk, which live here alone.
    var draftsOnly = false

    enum Grouping {
        case time, place
    }

    /// The entries this list speaks for: the Inbox's, the Drafts',
    /// one folder's, or everything.
    private var scopedEntries: [IndexEntry] {
        // Drafts leave the library lists, so their list reads straight
        // from the index.
        if draftsOnly {
            return state.index.timeline.reversed().filter { state.isDraft($0.doc) }
        }
        if let filedUnder {
            // Archived leaves the library lists, so its folder reads
            // straight from the filings.
            if filedUnder.caseInsensitiveCompare(AppState.archivedFolderName) == .orderedSame {
                return state.filedFolders
                    .filter { $0.value.caseInsensitiveCompare(filedUnder) == .orderedSame }
                    .compactMap { state.index.byID[$0.key] }
                    .sorted { $0.doc.listedDate > $1.doc.listedDate }
            }
            return state.filteredEntries.filter {
                state.folder(for: $0.doc)?.caseInsensitiveCompare(filedUnder) == .orderedSame
            }
        }
        guard inboxOnly else { return state.filteredEntries }
        return state.filteredEntries.filter {
            $0.doc.documentType == LiquidDoc.DocumentType.note.rawValue
                || state.isUnread($0.doc)
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
                    if draftsOnly {
                        ContentUnavailableView(
                            "No Drafts",
                            systemImage: "pencil.line",
                            description: Text("A new note starts here; the Draft toggle beside a note brings it back."))
                    } else if let filedUnder {
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
        // slice or the Drafts.
        guard filedUnder == nil, !draftsOnly else { return [] }
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
        return grouping == .place ? placeGroups(entries) : timeGroups(entries)
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

