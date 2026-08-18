import SwiftUI

/// One place in the sidebar: the document library, or an installed view
/// module by id. Views appear as `.view(id)`.
/// The Library section's shelves — the reference manager's doors.
enum SourceShelf: String, Hashable {
    case all, books, articles, authors, quotes
}

/// How a file library lists its works: every title A–Z, the authors
/// with their works under them, or the journals and proceedings the
/// works appeared in (read from each record's BibTeX).
enum FileShelfListing: String, Hashable {
    case alphabetical, authors, journals
}

/// Which transcripts a Transcripts place lists: every kind together,
/// the AI conversations, or the human meetings.
enum TranscriptScope: String, Hashable {
    case all, ai, meetings
}

enum SidebarItem: Hashable {
    case library      // the Inbox: what is new and unread
    case timeline     // every note, by time, latest on top
    case place        // the same notes, grouped by country and town
    case people       // the same notes, grouped by author
    case transcripts(TranscriptScope)  // meetings' and AI conversations' words
    case aiChats      // AI conversations captured from the web
    case notes        // only notes proper — not journals or other kinds
    case draftLetters // letters still being written
    case digests      // the granted documents folder, distilled
    case action(LiquidDoc.Action)  // notes by standing: To Do, Done…
    case important  // everything marked Important — those also standing To Do on top
    case sourceShelf(SourceShelf)  // the Library: sources, authors, quotes
    case pdfShelf(FileShelfListing)   // the Reader Library's PDFs, by a listing
    case epubShelf(FileShelfListing)  // the EPUB Library's works, by a listing
    case authorDocuments  // Author's .liquid documents, read in place
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

/// How much of the sidebar shows: Small is the pared-down default —
/// the head of the column, Actions, and Views — while Full carries the
/// whole catalog, Library and Digest and Filed and all. Chosen in
/// Settings ▸ Appearance, persisted like the theme.
enum SidebarLayout: String, CaseIterable, Identifiable {
    case small
    case full

    var id: String { rawValue }

    var label: String {
        switch self {
        case .small: "Small"
        case .full: "Full"
        }
    }

    static let key = "sidebarLayout"

    static var current: SidebarLayout {
        SidebarLayout(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .small
    }
}

enum SidebarCatalog {
    /// The grey every sidebar icon wears — place rows and action rows
    /// alike, so the column reads as one set.
    static var iconTint: Color { AppGreys.buttonText }

    /// The head of the column, unnamed: the Inbox and every way of
    /// seeing the correspondence, with New Note (added by the sidebar
    /// view) closing the list.
    static let top: [SidebarPlace] = [
        // Important leads the column: everything marked with the orange
        // bullet, the To Do standing on top.
        SidebarPlace(name: "Important", systemImage: "circle.fill", item: .important),
        SidebarPlace(name: "Inbox", systemImage: "tray", item: .library),
        SidebarPlace(name: "Timeline", systemImage: "clock", item: .timeline),
        SidebarPlace(name: "Places", systemImage: "mappin.and.ellipse", item: .place),
        // The Map view module, seated here under Places rather than
        // with the other views.
        SidebarPlace(name: "Map", systemImage: "map", item: .view("places")),
        SidebarPlace(name: "People", systemImage: "person.2", item: .people),
        SidebarPlace(name: "Draft Letters", systemImage: "envelope.open", item: .draftLetters),
    ]

    /// The Transcripts section: every meeting's and AI conversation's
    /// words under All, and each kind in a place of its own.
    static let transcriptShelves: [SidebarPlace] = [
        SidebarPlace(name: "All", systemImage: "text.bubble", item: .transcripts(.all)),
        SidebarPlace(name: "AI", systemImage: "sparkles", item: .transcripts(.ai)),
        SidebarPlace(name: "Meetings", systemImage: "person.3", item: .transcripts(.meetings)),
    ]

    /// The Small layout's Views: People (the contacts list — photos and
    /// all) and the Map lead — Timeline has moved to the head of the
    /// column — then every installed view module. Inbox, Places, and
    /// Draft Letters are set aside for now; Transcripts stand as their
    /// own section.
    static var smallViews: [SidebarPlace] {
        let order: [SidebarItem] = [.people, .view("places")]
        return order.compactMap { item in top.first { $0.item == item } } + views
    }

    /// The Library: the reference shelf — sources whole and by kind,
    /// the cited authors, and the quotes standing on the works. The
    /// articles row wears the reader's own word for it.
    static func shelves(articlesLabel: String) -> [SidebarPlace] {
        [
            SidebarPlace(name: "Sources", systemImage: "books.vertical", item: .sourceShelf(.all)),
            SidebarPlace(name: "Books", systemImage: "book.closed", item: .sourceShelf(.books)),
            SidebarPlace(name: articlesLabel, systemImage: "doc.plaintext", item: .sourceShelf(.articles)),
            SidebarPlace(name: "Authors", systemImage: "person.text.rectangle", item: .sourceShelf(.authors)),
            SidebarPlace(name: "Quotes", systemImage: "quote.opening", item: .sourceShelf(.quotes)),
            SidebarPlace(name: "Notes", systemImage: "note.text", item: .notes),
            SidebarPlace(name: "AI Chat", systemImage: "bubble.left.and.bubble.right", item: .aiChats),
        ]
    }

    /// The Author section: Author's .liquid documents, read in place
    /// from the Author folder and opened into Author itself — the way
    /// PDFs open into Reader. macOS only; Author lives there.
    static let author: [SidebarPlace] = [
        SidebarPlace(name: "Documents", systemImage: "doc.richtext",
                     item: .authorDocuments),
    ]

    /// The file libraries' sections: the Reader Library's PDFs and the
    /// EPUB Library's works, each offered three ways — every title
    /// A–Z, by author, and by the journal or proceedings it appeared
    /// in (read from each record's BibTeX).
    static let pdfShelves: [SidebarPlace] = [
        SidebarPlace(name: "Alphabetical", systemImage: "textformat",
                     item: .pdfShelf(.alphabetical)),
        SidebarPlace(name: "Authors", systemImage: "person.text.rectangle",
                     item: .pdfShelf(.authors)),
        SidebarPlace(name: "Journals", systemImage: "newspaper",
                     item: .pdfShelf(.journals)),
    ]

    static let epubShelves: [SidebarPlace] = [
        SidebarPlace(name: "Alphabetical", systemImage: "textformat",
                     item: .epubShelf(.alphabetical)),
        SidebarPlace(name: "Authors", systemImage: "person.text.rectangle",
                     item: .epubShelf(.authors)),
        SidebarPlace(name: "Journals", systemImage: "newspaper",
                     item: .epubShelf(.journals)),
    ]

    /// The Digest: a different set of data — the user's own documents
    /// folder distilled — so it stands as its own section, and its
    /// notes appear nowhere else.
    static let digest: [SidebarPlace] = [
        SidebarPlace(name: "Digests", systemImage: "doc.text.magnifyingglass",
                     item: .digests),
    ]

    /// The note column's standard files, each button's word beside the
    /// folder it files under. The sidebar's Filed section mirrors this.
    static let standardFiles: [(label: String, folder: String)] =
        [("Thought", "Thoughts"), ("Inspiration", "Inspirations"),
         ("Journal", "Journal"), ("Note", "Notes")]

    /// The Action section: the note's standing, one place per state —
    /// the lifecycle axis, orthogonal to filing, read from the notes
    /// themselves.
    static let actions: [SidebarPlace] = LiquidDoc.Action.allCases.map {
        SidebarPlace(name: $0.placeName, systemImage: icon(for: $0), item: .action($0))
    }

    static func icon(for action: LiquidDoc.Action) -> String {
        switch action {
        case .toDo: "checklist"
        case .inProgress: "clock"
        case .done: "checkmark.circle"
        case .cancelled: "xmark.circle"
        case .question: "questionmark.circle"
        }
    }

    /// The installed views — minus any module the head of the column
    /// already seats (the Map lives under Places).
    static var views: [SidebarPlace] {
        let seated = Set(top.map(\.item))
        return LibraryViewRegistry.modules
            .filter { !seated.contains(.view($0.id)) }
            .map { SidebarPlace(name: $0.name, systemImage: $0.systemImage, item: .view($0.id)) }
    }

    /// Filed is a heading, not a click: each folder in use stands as
    /// its own place, one click from its contents. The place shows the
    /// folder's display name — its alias when renamed — while the item
    /// keeps the canonical name, which is the folder's identity.
    static func filed(_ folders: [String],
                      displayName: (String) -> String = { $0 }) -> [SidebarPlace] {
        folders.map {
            SidebarPlace(name: displayName($0),
                         systemImage: filedIcon(for: $0),
                         item: .filedFolder($0))
        }
    }

    private static func filedIcon(for folder: String) -> String {
        switch folder {
        case "Thoughts": return "lightbulb"
        case "Inspirations": return "quote.bubble"
        case "Journal": return "book.closed"
        case "Notes": return "note.text"
        case "Letters": return "envelope"
        case AppState.archivedFolderName: return "archivebox"
        default: return "folder"
        }
    }

    static func sections(filedFolders: [String],
                         folderDisplayName: (String) -> String = { $0 },
                         articlesLabel: String = "Articles",
                         layout: SidebarLayout = .small) -> [(title: String, places: [SidebarPlace])] {
        var result: [(title: String, places: [SidebarPlace])]
        switch layout {
        case .full:
            // Actions left the sidebar for the persistent column at the
            // list's right edge (ActionFilterColumn), where they filter
            // instead of navigate.
            result = [("", top),
                      ("Transcripts", transcriptShelves),
                      ("Library", shelves(articlesLabel: articlesLabel)),
                      ("Digest", digest),
                      ("Filed", filed(filedFolders, displayName: folderDisplayName)),
                      ("Views", views)]
            #if os(macOS)
            // The file libraries and Author's documents stand as their
            // own sections after the Library — the works as files, and
            // the documents read here but written in Author.
            result.insert(("PDF Library", pdfShelves), at: 3)
            result.insert(("EPUB Library", epubShelves), at: 4)
            result.insert(("Author", author), at: 5)
            #endif
        case .small:
            // The pared-down default: Timeline on top, unnamed, then
            // every filing folder under Files — Thoughts, Inspirations,
            // Journal, Notes, Letters, the user's own (Work, Personal…),
            // Archived last — then Views, where People and the Map lead
            // the modules. Library and Digest set aside; Actions (and
            // with them To Do) live in the column at the list's right
            // edge; New lives in ⌘N and the toolbar.
            var small: [(title: String, places: [SidebarPlace])] = []
            // The unnamed head: Important first, then Timeline.
            let head = [SidebarItem.important, .timeline].compactMap { item in
                top.first { $0.item == item }
            }
            if !head.isEmpty {
                small.append(("", head))
            }
            if !filedFolders.isEmpty {
                small.append(("Files", filed(filedFolders, displayName: folderDisplayName)))
            }
            // Transcripts stand as their own section in both layouts:
            // every kind under All, the AI conversations and the human
            // meetings each in a place of their own.
            small.append(("Transcripts", transcriptShelves))
            #if os(macOS)
            // The file libraries: the Reader Library's PDFs and the
            // EPUB Library's works, each by title, author, or journal.
            small.append(("PDF Library", pdfShelves))
            small.append(("EPUB Library", epubShelves))
            small.append(("Author", author))
            #endif
            small.append(("Views", smallViews))
            result = small
        }
        return result
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
    /// What "Show in <View>" hands this view: `.text` for views about
    /// text snippets (the selected words travel), `.note` for views
    /// about notes as nodes (the whole note travels). The view picks
    /// the payload up with `model.takeShowInPayload(for:)`.
    var showInAppetite: ShowInAppetite = .note

    enum ShowInAppetite { case text, note }
}

/// The installed views, in sidebar order.
@MainActor
enum LibraryViewRegistry {
    static let modules: [LibraryViewModule] = [
        AskLibraryView.module,
        SphereWeaveView.module,
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
        #if DEBUG
        _ = uniqueIDCheck
        #endif
        return modules.first { $0.id == id }
    }

    static func module(for item: SidebarItem?) -> LibraryViewModule? {
        guard case .view(let id)? = item else { return nil }
        return module(id: id)
    }

    #if DEBUG
    /// A module is reached by its id, so two modules sharing one leave a
    /// view unreachable — the sidebar shows both rows, but every click on
    /// either opens whichever the registry lists first. That is silent in
    /// a release build and maddening to a module author, so it trips an
    /// assertion here. Evaluated once, on first lookup.
    private static let uniqueIDCheck: Void = {
        let counts = Dictionary(grouping: modules.map(\.id), by: { $0 })
        let duplicates = counts.filter { $0.value.count > 1 }.keys.sorted()
        assert(duplicates.isEmpty,
               "Duplicate view-module id(s): \(duplicates.joined(separator: ", ")). "
               + "Each LibraryViewModule needs a unique id.")
    }()
    #endif
}

/// The persistent Actions column at the right edge of every document
/// list — the lifecycle axis, orthogonal to filing, standing beside the
/// notes it sorts. Choosing a standing narrows whatever list the sidebar
/// has open to notes carrying it; choosing it again lets the list back
/// out. Nothing is ever demanded: with no choice made, the column only
/// stands and waits.
struct ActionFilterColumn: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Actions")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.leading, 8)
                .padding(.bottom, 4)
            // All leads the column and is the resting state: no filter,
            // the whole list. It wears the chosen look whenever no
            // standing below has taken over.
            allRow
            ForEach(LiquidDoc.Action.allCases, id: \.self) { action in
                row(action)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
        .padding(.horizontal, 6)
        .frame(width: 126, alignment: .leading)
    }

    private var allRow: some View {
        let chosen = state.listActionFilter == nil
        return Button {
            withAnimation(.snappy) { state.listActionFilter = nil }
        } label: {
            Label("All", systemImage: "list.bullet")
                .font(.callout)
                .foregroundStyle(chosen ? Color.primary : SidebarCatalog.iconTint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(chosen ? Color.primary.opacity(0.08) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Everything in the current list, whatever its standing")
    }

    private func row(_ action: LiquidDoc.Action) -> some View {
        let chosen = state.listActionFilter == action
        return Button {
            withAnimation(.snappy) {
                state.listActionFilter = chosen ? nil : action
            }
        } label: {
            Label(action.placeName, systemImage: SidebarCatalog.icon(for: action))
                .font(.callout)
                .foregroundStyle(chosen ? Color.primary : SidebarCatalog.iconTint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(chosen ? Color.primary.opacity(0.08) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(chosen ? "Show everything again"
              : "Only \(action.placeName) in the current list")
        #if os(macOS)
        // A standing's row starts a note with that standing — New To Do,
        // New Question — as its sidebar place did before the move here.
        .contextMenu {
            Button("New \(action.displayName)") { state.newNote(action: action) }
        }
        #endif
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
    /// The Draft Letters list: letters still being written.
    var draftLettersOnly = false
    /// The Transcripts places: All, the AI conversations, or the human
    /// meetings — newest first either way.
    var transcripts: TranscriptScope? = nil
    /// The AI Chat list: conversations captured from the web, newest first.
    var aiChatsOnly = false
    /// The Notes list: notes proper only — the quick own-hand kind,
    /// not journals, letters, sources, or any other document type.
    var notesOnly = false
    /// The Digest list: the granted folder's distillations — kept out
    /// of every other list, this one reads the index directly.
    var digestsOnly = false
    /// Narrows the list to notes with one action standing.
    var action: LiquidDoc.Action? = nil
    /// The orange head of the column: everything marked Important,
    /// the notes also standing To Do on top.
    var importantOnly = false

    /// Whether the inline note's controls are unfolded — each newly
    /// opened note starts with them tucked away.
    @State private var controlsRevealed = false
    /// The grace period between the pointer leaving the Show Column
    /// icon (or the column) and the column folding away.
    @State private var controlsHideTask: Task<Void, Never>?
    /// Full screen peeks the controls in from the right edge, so the
    /// open row keeps its Show Column button out of the way there.
    @Environment(\.inFullScreen) private var inFullScreen

    enum Grouping {
        case time, place
    }

    /// The entries this list speaks for: the Inbox's, one standing's,
    /// one folder's, or everything.
    private var scopedEntries: [IndexEntry] {
        if importantOnly {
            // Everything marked Important, the To Do standing on top —
            // each band keeping the list's own newest-first order.
            let important = state.filteredEntries.filter { $0.doc.important }
            return important.filter { $0.doc.actionValue == .toDo }
                + important.filter { $0.doc.actionValue != .toDo }
        }
        if let action {
            return state.filteredEntries.filter { $0.doc.actionValue == action }
        }
        if let filedUnder {
            // A folder's list reads straight from the filings, so it
            // shows every note filed there — however the library lists
            // treat the note otherwise.
            let filedIDs = state.filedFolders
                .filter { $0.value.caseInsensitiveCompare(filedUnder) == .orderedSame }
                .map(\.key)
            var seen = Set(filedIDs)
            var entries = filedIDs.compactMap { state.index.allByID[$0] }
            // A kind folder — Thoughts, Inspirations, Journal — also
            // gathers every note whose own documentType is that kind,
            // so a note marked Inspiration lists here even when the
            // filing lives only in the file (set on the phone, or by a
            // kind the note carries between devices). Archived notes
            // keep out; the timeline already excludes them.
            if let kind = AppState.kindFolder(for: filedUnder) {
                for entry in state.index.timeline
                where entry.doc.documentType == kind && !seen.contains(entry.id) {
                    entries.append(entry)
                    seen.insert(entry.id)
                }
            }
            return entries.sorted { $0.doc.listedDate > $1.doc.listedDate }
        }
        if draftLettersOnly {
            return state.filteredEntries.filter {
                $0.doc.documentType == LiquidDoc.DocumentType.letter.rawValue
                    && state.isDraft($0.doc)
            }
        }
        if let transcripts {
            // The human meetings read the filtered timeline; the AI
            // conversations are often drafts (captures land that way)
            // and so read the index directly. The two sets are disjoint
            // — a meeting is a transcript that is not an AI conversation.
            let meetings = state.filteredEntries.filter {
                Self.isTranscript($0.doc) && !$0.doc.isAIConversation
            }
            switch transcripts {
            case .meetings: return meetings
            case .ai: return aiConversationEntries
            case .all: return (meetings + aiConversationEntries)
                .sorted { $0.doc.listedDate > $1.doc.listedDate }
            }
        }
        if notesOnly {
            // Notes proper: the `note` document type alone — journals,
            // letters, and every other kind keep to their own places.
            return state.filteredEntries.filter {
                $0.doc.documentType == LiquidDoc.DocumentType.note.rawValue
            }
        }
        if aiChatsOnly {
            return aiConversationEntries
        }
        if digestsOnly {
            // Digests are excluded from listedEntries (and so from
            // every other list); their own place reads the index.
            let entries = state.index.timeline.reversed().filter { $0.doc.isDigest }
            guard !state.searchText.isEmpty else { return Array(entries) }
            return entries.filter {
                $0.doc.title.localizedCaseInsensitiveContains(state.searchText)
                    || $0.doc.bodyEditingText.localizedCaseInsensitiveContains(state.searchText)
            }
        }
        guard inboxOnly else { return state.filteredEntries }
        // The Inbox is only what still awaits a verdict: nothing filed,
        // no action standing set. A letter being written lives under
        // Draft Letters, and the old standing To Do and Done notes keep
        // out of the way.
        return state.filteredEntries.filter { entry in
            // The open note keeps its seat: setting an Action or filing
            // it would move it out of the Inbox, but not from under the
            // reader — it leaves when they click away.
            if entry.id == state.selectedDocID { return true }
            guard !entry.doc.isLibraryKind else { return false }
            let type = entry.doc.documentType
            let isLetter = type == LiquidDoc.DocumentType.letter.rawValue
            return (type == LiquidDoc.DocumentType.note.rawValue || isLetter
                || state.isUnread(entry.doc))
                && !(isLetter && state.isDraft(entry.doc))
                && entry.doc.action == nil
                && state.folder(for: entry.doc) == nil
                && !Self.pinnedTitles.contains {
                    entry.doc.title.trimmingCharacters(in: .whitespaces)
                        .caseInsensitiveCompare($0) == .orderedSame
                }
        }
    }

    /// The AI conversations, newest first: captured chats land as
    /// drafts and stay out of the main lists, so this reads the index
    /// directly — whatever a conversation's draft or filing state,
    /// the way Digests do.
    private var aiConversationEntries: [IndexEntry] {
        let entries = state.index.timeline.reversed().filter {
            $0.doc.documentType == LiquidDoc.DocumentType.aiConversation.rawValue
        }
        guard !state.searchText.isEmpty else { return Array(entries) }
        return entries.filter {
            $0.doc.title.localizedCaseInsensitiveContains(state.searchText)
                || $0.doc.bodyEditingText.localizedCaseInsensitiveContains(state.searchText)
        }
    }

    /// The Actions column's filter, laid over whatever scope the
    /// sidebar chose. The open document keeps its seat — changing a
    /// note's standing must not snatch it out from under the writer.
    private var displayedEntries: [IndexEntry] {
        guard let filter = state.listActionFilter else { return scopedEntries }
        return scopedEntries.filter {
            $0.doc.actionValue == filter || $0.id == state.selectedDocID
        }
    }

    /// A transcript is a document declared `transcript`, or — for
    /// documents from before the type existed — one whose body carries
    /// at least two distinct speaker attributions. Digital Letters'
    /// predicate, word for word.
    static func isTranscript(_ doc: LiquidDoc) -> Bool {
        if doc.documentType == LiquidDoc.DocumentType.transcript.rawValue { return true }
        return Set((doc.body ?? []).compactMap(\.speaker)).count >= 2
    }

    /// The list's selection. "In the list", the expanded note is its
    /// own evidence of being open, so the list reports no selection —
    /// no accent highlight swallowing the writing page.
    private var listSelection: Binding<String?> {
        Binding(
            get: { state.notesOpenInList ? nil : state.selectedDocID },
            set: { if let id = $0 { state.selectedDocID = id } }
        )
    }

    var body: some View {
        // The Actions column stands at the list's right edge, always:
        // the sidebar says where you are looking, the column says what
        // standing you want to see there. The two compose. Full screen
        // hides it with the sidebar; the right edge peeks it back in
        // (ContentView's peek), the same way the left edge answers.
        HStack(spacing: 0) {
            listColumn
            if !inFullScreen {
                Divider()
                ActionFilterColumn()
            }
        }
    }

    private var listColumn: some View {
        VStack(spacing: 0) {
            List(selection: listSelection) {
                // A bare place the search has placed awaits the reader's
                // word before it groups under that country.
                if grouping == .place, !state.places.pendingVerification.isEmpty {
                    Section("Confirm Places") {
                        ForEach(state.places.pendingVerification) { record in
                            placeVerificationRow(record)
                        }
                    }
                }
                ForEach(groups, id: \.label) { group in
                    Section {
                        // The day stands as the first row of its group,
                        // inline with the notes and scrolling with them —
                        // no header bar of its own. A shade lighter than
                        // the notes' words, and receding with the rows
                        // while one is written in.
                        Text(group.label)
                            .font(state.listHeadingFont)
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                            .padding(.top, 6)
                            .opacity(state.dimsListWhileEditing && state.editingInList ? 0.3 : 1)
                        ForEach(group.entries) { entry in
                            Group {
                                // "In the list" (Settings ▸ Appearance):
                                // the clicked document grows in place —
                                // a note into its writing page, other
                                // kinds into their reading — all the
                                // words held, no pane opening.
                                if isExpanded(entry) {
                                    // Thin rules above and below mark
                                    // where the open document begins
                                    // and the list resumes.
                                    VStack(spacing: 0) {
                                        openNoteRule
                                        // The close spot stands left of
                                        // the first line — a click there
                                        // folds the document away. A
                                        // read document (a transcript, a
                                        // source) wears the chevron; a
                                        // note's writing page keeps the
                                        // spot unmarked, known to the
                                        // hand. At the top right, Show
                                        // Column brings the note's
                                        // controls in as a column beside
                                        // the words.
                                        HStack(alignment: .top, spacing: 4) {
                                            closeToggle(visible: !ContentView.isWritable(entry.doc))
                                            // The open note wears the same
                                            // orange Important bullet its
                                            // closed row does, so the mark
                                            // does not vanish when it opens.
                                            if entry.doc.important {
                                                Image(systemName: "circle.fill")
                                                    .font(.system(size: 7))
                                                    .foregroundStyle(.orange)
                                                    .accessibilityLabel("Important")
                                                    .padding(.top, 6)
                                            }
                                            // A note writes; every other
                                            // kind — a transcript, a
                                            // source — reads. Both carry
                                            // the Show Column button, so
                                            // the controls reach a read
                                            // document as well.
                                            if ContentView.isWritable(entry.doc) {
                                                NoteWritingView(doc: entry.doc, inline: true)
                                                    .id(entry.doc.id)
                                                    .padding(.vertical, 6)
                                            } else {
                                                DocumentReaderView(doc: entry.doc, inline: true)
                                                    .id(entry.doc.id)
                                                    .padding(.vertical, 6)
                                            }
                                            if !inFullScreen {
                                                columnToggle
                                            }
                                        }
                                        openNoteRule
                                    }
                                } else {
                                    DocumentRow(entry: entry, detail: detail(for: entry.doc),
                                                filingFolder: actionListFiling(for: entry.doc),
                                                actionPill: folderListAction(for: entry.doc),
                                                expandedPreview: filedUnder != nil)
                                        // While a note's words are being
                                        // typed, the rest of the list
                                        // recedes.
                                        .opacity(state.dimsListWhileEditing && state.editingInList ? 0.3 : 1)
                                        // Closed rows share the open
                                        // note's left margin, so the
                                        // reveal triangle sits in the
                                        // list's own indent instead of
                                        // pushing the open note aside.
                                        .padding(.leading, state.notesOpenInList ? 18 : 0)
                                }
                            }
                            .tag(entry.id)
                            // An open document is not a selectable row:
                            // without this, clicking — or selecting
                            // text in — an expanded reading page makes
                            // the List paint its accent over the whole
                            // open document. (A note's editor eats the
                            // clicks; a read-only page lets them fall
                            // through to the row.)
                            .selectionDisabled(isExpanded(entry))
                            .listRowSeparator(.hidden)
                            // A folder's rows keep the Filed list's
                            // put-it-back.
                            .contextMenu {
                                if filedUnder != nil {
                                    Button("Unfile") { state.unfile(entry.doc) }
                                }
                                #if os(macOS)
                                if entry.doc.isDigest {
                                    Button("Open Original") {
                                        state.openDigestOriginal(entry.doc)
                                    }
                                }
                                Button("Rename File…") {
                                    state.renameFile(of: entry.doc)
                                }
                                if filedUnder != nil {
                                    Button("Delete File…", role: .destructive) {
                                        state.deleteFile(entry.doc)
                                    }
                                }
                                #endif
                            }
                        }
                    }
                }
                if state.index.isScanning {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.tertiary)
                        .opacity(0.4)
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
            // The list also pads the top of its scroll content before
            // the first heading; that air is the frame's, not the text's.
            .contentMargins(.top, 0, for: .scrollContent)
            .overlay {
                if state.index.folderURL != nil, displayedEntries.isEmpty,
                   !state.index.isScanning {
                    if let filter = state.listActionFilter, !scopedEntries.isEmpty {
                        ContentUnavailableView(
                            "Nothing \(filter.displayName)",
                            systemImage: SidebarCatalog.icon(for: filter),
                            description: Text("No note here carries this standing — choose it again in the Actions column to see everything."))
                    } else if draftLettersOnly {
                        ContentUnavailableView(
                            "No Draft Letters",
                            systemImage: "envelope.open",
                            description: Text("A new letter starts here; its Letter button files it under Letters when it is done."))
                    } else if aiChatsOnly {
                        ContentUnavailableView(
                            "No AI Chats",
                            systemImage: "bubble.left.and.bubble.right",
                            description: Text("Capture a conversation from claude.ai, ChatGPT, or Gemini with the Safari extension’s “Send to Knowledge Space” — it lands here as a draft."))
                    } else if let transcripts {
                        switch transcripts {
                        case .all:
                            ContentUnavailableView(
                                "No Transcripts",
                                systemImage: "text.bubble",
                                description: Text("Import a transcript with File ▸ Import Transcript… — meetings and AI conversations both list here."))
                        case .ai:
                            ContentUnavailableView(
                                "No AI Transcripts",
                                systemImage: "sparkles",
                                description: Text("Import an AI conversation with File ▸ Import Transcript…, or capture one with the Safari extension, and it lists here."))
                        case .meetings:
                            ContentUnavailableView(
                                "No Meetings",
                                systemImage: "person.3",
                                description: Text("Import a meeting transcript with File ▸ Import Transcript… — speaker names before statements — and it lists here."))
                        }
                    } else if notesOnly {
                        ContentUnavailableView(
                            "No Notes",
                            systemImage: "note.text",
                            description: Text("A note is the quickest kind — ⌘N, or New Note in the sidebar — and every one you write lists here."))
                    } else if importantOnly {
                        ContentUnavailableView(
                            "Nothing Marked Important",
                            systemImage: "circle.fill",
                            description: Text("A note marked Important lists here — any also standing To Do on top."))
                    } else if let action {
                        ContentUnavailableView(
                            "Nothing \(action.displayName)",
                            systemImage: SidebarCatalog.icon(for: action),
                            description: Text("Give a note this standing — in the Action row beside it — and it lists here."))
                    } else if let filedUnder {
                        ContentUnavailableView(
                            "Nothing Here",
                            systemImage: "checklist",
                            description: Text("File a note under \(state.displayName(forFolder: filedUnder)) — from the column beside the reader — and it lists here."))
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
        // A different note opens with its controls tucked away again.
        .onChange(of: state.selectedDocID) { controlsRevealed = false }
        // The fade around the written-in note comes and goes gently.
        .animation(.easeOut(duration: 0.25), value: state.editingInList)
        // The open note's controls, summoned by its Show Column icon:
        // a full-height panel floating over the list's right edge, so
        // every control has its room and the note keeps its shape.
        .overlay(alignment: .topTrailing) {
            if controlsRevealed, !inFullScreen,
               let doc = state.selectedDoc {
                NoteOptionsColumn(doc: doc)
                    .frame(maxHeight: .infinity)
                    .clipShape(UnevenRoundedRectangle(
                        topLeadingRadius: 10, bottomLeadingRadius: 10,
                        bottomTrailingRadius: 0, topTrailingRadius: 0))
                    .shadow(radius: 6, x: -2, y: 0)
                    // The pointer inside the panel keeps it; leaving
                    // lets it go. A geometry sensor, not .onHover: the
                    // controls' own tracking (buttons, tooltips) must
                    // not read as leaving.
                    #if os(macOS)
                    .background(HoverSensor { inside in
                        if inside {
                            cancelControlsHide()
                        } else {
                            scheduleControlsHide()
                        }
                    })
                    #endif
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    /// Whether this entry is the document open in the list itself.
    private func isExpanded(_ entry: IndexEntry) -> Bool {
        state.notesOpenInList && entry.id == state.selectedDocID
    }

    /// The rules above and below an open document: finer and lighter
    /// than the window's standard divider, framing without weight.
    private var openNoteRule: some View {
        Rectangle()
            .fill(Color.black.opacity(0.08))
            .frame(height: 0.5)
    }

    /// The open document's disclosure, left of its first line: clicking
    /// folds the document back into its row. On a read document — a
    /// transcript, a source — the down-pointing chevron shows the way
    /// shut; on a note's writing page the same spot stays unmarked —
    /// there the fold-away is for hands that know it, not a mark on
    /// the page. Closed rows wear no mark; clicking the row is the
    /// way in.
    private func closeToggle(visible: Bool) -> some View {
        Button {
            withAnimation(.snappy) { state.selectedDocID = nil }
        } label: {
            Group {
                if visible {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Circle()
                        .fill(.clear)
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
        .help("Close — the document folds back into the list")
    }

    /// Show Column, at the open note's top right: resting the pointer
    /// on it brings the note's controls in as a column beside the
    /// words; the column stays while the pointer is with it and folds
    /// away once it leaves. A click answers the same way.
    private var columnToggle: some View {
        Button {
            controlsHideTask?.cancel()
            withAnimation(.snappy) { controlsRevealed.toggle() }
        } label: {
            Image(systemName: "sidebar.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(controlsRevealed ? .primary : .secondary)
                .padding(.vertical, 10)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                cancelControlsHide()
                withAnimation(.snappy) { controlsRevealed = true }
            } else {
                scheduleControlsHide()
            }
        }
        .help("The note's controls column — it comes to the pointer and leaves with it")
    }

    /// An unhurried grace: the pointer can travel from the icon across
    /// the note into the panel — or drift out and think better of it —
    /// without the panel vanishing under it.
    private func scheduleControlsHide() {
        controlsHideTask?.cancel()
        controlsHideTask = Task {
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { controlsRevealed = false }
        }
    }

    private func cancelControlsHide() {
        controlsHideTask?.cancel()
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

    /// "To Do" and "Done" — ordinary notes the library keeps standing
    /// (see AppState.ensureStandingNotes()). They list under their own
    /// dates like any note, never pinned; the Inbox leaves them out
    /// entirely, their Filed places being their homes.
    static let pinnedTitles = ["To Do", "Done"]

    // MARK: Grouping

    private var groups: [(label: String, entries: [IndexEntry])] {
        // The Important list keeps its own two shelves — To Do on top,
        // the rest of Important beneath — instead of day headings.
        if importantOnly { return importantGroups(displayedEntries) }
        switch grouping {
        case .place: return placeGroups(displayedEntries)
        case .time: return timeGroups(displayedEntries)
        }
    }

    private func importantGroups(_ entries: [IndexEntry]) -> [(label: String, entries: [IndexEntry])] {
        let toDo = entries.filter { $0.doc.actionValue == .toDo }
        let rest = entries.filter { $0.doc.actionValue != .toDo }
        var groups: [(label: String, entries: [IndexEntry])] = []
        if !toDo.isEmpty { groups.append((label: "To Do", entries: toDo)) }
        if !rest.isEmpty { groups.append((label: "Important", entries: rest)) }
        return groups
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

    /// The Action lists (To Do, In Progress, Done…) wear a pill saying
    /// which folder each note is filed under; every other list leaves
    /// it off. Nil when this is not an Action list, or the note is
    /// filed nowhere.
    private func actionListFiling(for doc: LiquidDoc) -> String? {
        guard action != nil else { return nil }
        return state.folder(for: doc)
    }

    /// The folder lists wear a pill saying each note's action standing —
    /// To Do, Done… — clicking it opens that Action list. Nil when this
    /// is not a folder list, or the note has no standing.
    private func folderListAction(for doc: LiquidDoc) -> LiquidDoc.Action? {
        guard filedUnder != nil else { return nil }
        return doc.actionValue
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
    /// The record a ctrl-click asked to delete, held for the
    /// confirmation dialog.
    @State private var deletingListing: PersonListing?
    /// Bumped after a delete so the list rebuilds from the freshly
    /// pruned directory.
    @State private var reloadToken = UUID()
    /// Whether the hidden people are being shown for now — off until the
    /// reader asks to see them, so they can be brought back.
    @State private var showingHidden = false

    /// The listings, alphabetical from AppState: Show in People's
    /// one-person narrowing first, then the search field on name,
    /// alias, or affiliation.
    private var people: [PersonListing] {
        var listings = state.peopleListings
        if let name = state.peopleFilterName {
            listings = listings.filter { $0.person.answersTo(name) }
        }
        guard !state.searchText.isEmpty else { return listings }
        return listings.filter { listing in
            listing.person.displayName.localizedCaseInsensitiveContains(state.searchText)
                || listing.person.affiliation.localizedCaseInsensitiveContains(state.searchText)
                || (listing.person.aliases ?? []).contains {
                    $0.localizedCaseInsensitiveContains(state.searchText)
                }
        }
    }

    /// The rows shown: hidden people kept out unless the reader is
    /// showing them for now.
    private var visiblePeople: [PersonListing] {
        people.filter { showingHidden || !state.hiddenPeople.contains($0.id) }
    }

    /// The highlighted people, in the same alphabetical order — they
    /// stand at the top of the list under no heading.
    private var highlightedPeople: [PersonListing] {
        visiblePeople.filter { state.highlightedPeople.contains($0.id) }
    }

    /// Everyone else, below the highlighted and their divider.
    private var regularPeople: [PersonListing] {
        visiblePeople.filter { !state.highlightedPeople.contains($0.id) }
    }

    /// How many people are hidden right now — what the reveal at the
    /// foot offers to bring back.
    private var hiddenCount: Int {
        people.filter { state.hiddenPeople.contains($0.id) }.count
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
            // Narrowed to one person by Show in People: say so, and
            // offer the whole list back.
            if state.peopleFilterName != nil {
                Button {
                    state.peopleFilterName = nil
                } label: {
                    Label("Show All People", systemImage: "chevron.left")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
            }
            // The highlighted stand first, under no heading, a divider
            // closing the group.
            ForEach(highlightedPeople) { listing in
                personListRow(listing)
            }
            if !highlightedPeople.isEmpty, !regularPeople.isEmpty {
                Divider()
                    .listRowSeparator(.hidden)
            }
            ForEach(regularPeople) { listing in
                personListRow(listing)
            }
            // The way back for hidden people: a quiet reveal at the foot.
            if hiddenCount > 0 {
                Button {
                    showingHidden.toggle()
                } label: {
                    Label(showingHidden ? "Hide Hidden People"
                                        : "Show \(hiddenCount) Hidden",
                          systemImage: showingHidden ? "eye.slash" : "eye")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
            }
        }
        // A fresh id after each delete reloads the list from the pruned
        // directory.
        .id(reloadToken)
        .overlay {
            if people.isEmpty, state.index.folderURL != nil,
               !state.index.isScanning {
                ContentUnavailableView(
                    "No People",
                    systemImage: "person.2",
                    description: Text("People appear here from the shared folder's contact records — Digital Letters' People.json and the phone's identity cards. Rest the pointer on People in the sidebar and click its triangle to add someone."))
            }
        }
        #if os(macOS)
        .sheet(item: $editingListing) { listing in
            PersonFormView(person: listing.person, heading: "Edit Record") { updated in
                state.people.upsert(updated)
                state.publishPortraits()
                state.index.rescan()
            }
        }
        .confirmationDialog(
            "Delete \(deletingListing?.person.displayName ?? "Person")?",
            isPresented: Binding(get: { deletingListing != nil },
                                 set: { if !$0 { deletingListing = nil } }),
            presenting: deletingListing
        ) { listing in
            Button("Delete", role: .destructive) { delete(listing) }
        } message: { _ in
            Text("The record, its portrait, and the person's identity card move to the Trash. Their other notes and documents stay in the library.")
        }
        #endif
    }

    #if os(macOS)
    /// Removes the person entirely: their directory record, their
    /// portrait, and their identity-card document — so they do not
    /// return from the folder on the next scan. Clears the reading
    /// column if their card was open there.
    private func delete(_ listing: PersonListing) {
        state.portraits.removeImages(for: listing.person.localID)
        state.people.remove(listing.person)
        state.deleteIdentityCards(for: listing)
        if state.selectedPersonID == listing.id { state.selectedPersonID = nil }
        state.publishPortraits()
        state.index.rescan()
        // Rebuild the list so the removed person is gone at once.
        reloadToken = UUID()
    }
    #endif

    /// One row of the list: the person, tagged for selection, dimmed
    /// while shown among the hidden, with the full ctrl-click menu.
    private func personListRow(_ listing: PersonListing) -> some View {
        let isHidden = state.hiddenPeople.contains(listing.id)
        return personRow(listing)
            .opacity(isHidden ? 0.5 : 1)
            .tag(listing.id)
            .listRowSeparator(.hidden)
            #if os(macOS)
            .contextMenu {
                Button(state.highlightedPeople.contains(listing.id)
                       ? "Unhighlight" : "Highlight") {
                    state.toggleHighlightedPerson(listing.id)
                }
                if isHidden {
                    Button("Unhide") { state.setPersonHidden(false, listing.id) }
                } else {
                    Button("Hide") { state.setPersonHidden(true, listing.id) }
                }
                Divider()
                Button("Edit Record…") { editingListing = listing }
                Divider()
                Button("Delete Person…", role: .destructive) {
                    deletingListing = listing
                }
            }
            #endif
    }

    private func personRow(_ listing: PersonListing) -> some View {
        let mentionCount = state.index.mentions[listing.id]?.count ?? 0
        return HStack(spacing: 10) {
            PersonAvatarView(name: listing.person.displayName, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(listing.person.displayName)
                    if listing.person.isArtificial {
                        aiBadge
                    }
                }
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

    /// The quiet mark of a model among people.
    private var aiBadge: some View {
        Text("AI")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.quaternary))
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

/// A person's page in the reading column: their contact details under
/// their face and name, then the notes that name them, newest first.
/// Clicking a note opens it in this column's place.
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
            contactDetails(listing.person)
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

    /// The record's lines, under the name — affiliation rides with the
    /// name itself, so it is not repeated here.
    @ViewBuilder private func contactDetails(_ person: Person) -> some View {
        let details: [(String, String)] = [
            ("ORCID", person.orcid),
            ("Version", person.aiVersion ?? ""),
            ("Email", person.emails.joined(separator: ", ")),
            ("Aliases", (person.aliases ?? []).joined(separator: ", ")),
            ("Profile", person.publicProfile ?? ""),
        ].filter { !$0.1.isEmpty }
        ForEach(details, id: \.0) { label, value in
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .listRowSeparator(.hidden)
        }
    }
}

