import SwiftUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

/// The library window: places in the sidebar (the document library and
/// every installed view module), the documents or a module's content in
/// the middle, and the reader — or a module's canvas — in the detail
/// column. `origamitext://` links anywhere inside route back through
/// AppState so citations navigate in place.
struct ContentView: View {
    @Environment(AppState.self) private var state
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingFolderPicker = false
    #if os(macOS)
    /// The Timeline calendar sheet: choose a year, month, or day to be
    /// the span the notes list shows.
    @State private var showingTimelineCalendar = false
    #endif
    /// Full screen is a focus mode, entered and left with ESC — like
    /// Origami Text and Author: only the reading area shows.
    @State private var isFullScreen = false
    /// The sidebar has no toggle — it is the way to every place — so
    /// its column stays open no matter what state the window restores
    /// with or what a stray gesture collapses.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    #if os(macOS)
    /// Full screen keeps a doorway: hovering the left edge slides the
    /// sidebar in as an overlay; moving away lets it fade.
    @State private var showsPeekSidebar = false
    /// Clicking a sidebar place in the peek unfolds a second column
    /// listing its contents, so other notes open without leaving
    /// full screen.
    @State private var showsPeekList = false
    @State private var peekHideTask: Task<Void, Never>?
    /// The right edge answers the same way: hovering it slides the
    /// open document's options column in as an overlay.
    @State private var showsPeekOptions = false
    @State private var peekOptionsHideTask: Task<Void, Never>?
    #endif

    var body: some View {
        @Bindable var state = state
        Group {
            if isFullScreen {
                fullScreenPane
                    #if os(macOS)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .leading) {
                        peekSidebar
                    }
                    .overlay(alignment: .trailing) {
                        peekOptionsColumn
                    }
                    #endif
            } else if LibraryViewRegistry.module(for: state.sidebarSelection)?.hidesDocumentList == true {
                // Whole-library views keep the sidebar — the way to every
                // other place — and give the canvas the list column's room.
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    LibrarySidebarView()
                        #if os(macOS)
                        .toolbar(removing: .sidebarToggle)
                        #endif
                } detail: {
                    detailPane
                }
            } else if state.notesOpenInList {
                // "In the list": two columns only — the sidebar and the
                // list, which is the page. No third pane at all.
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    LibrarySidebarView()
                        #if os(macOS)
                        .toolbar(removing: .sidebarToggle)
                        #endif
                } detail: {
                    contentPane
                        .scrollContentBackground(.hidden)
                        .background(AppGreys.page)
                        .environment(\.colorScheme, .light)
                        #if os(macOS)
                        .safeAreaInset(edge: .bottom, spacing: 0) { findBar }
                        .safeAreaInset(edge: .top, spacing: 0) {
                            contentHeader
                        }
                        #endif
                }
                #if !os(macOS)
                .searchable(text: $state.searchText, prompt: "Title, author, or text")
                #endif
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    LibrarySidebarView()
                        #if os(macOS)
                        .toolbar(removing: .sidebarToggle)
                        #endif
                } content: {
                    contentPane
                        // The list stands on the design's page grey,
                        // whatever the system appearance.
                        .scrollContentBackground(.hidden)
                        .background(AppGreys.page)
                        .environment(\.colorScheme, .light)
                        // The list is a spine, not a page: it keeps to a
                        // modest width so the words get the room.
                        .navigationSplitViewColumnWidth(min: 150, ideal: 225, max: 340)
                        #if os(macOS)
                        // Find sits framed at the foot of the notes list
                        // and filters it; the Timeline heading sits as a
                        // plain header at its top, outside the toolbar so
                        // it doesn't get wrapped in a glass capsule.
                        .safeAreaInset(edge: .bottom, spacing: 0) { findBar }
                        .safeAreaInset(edge: .top, spacing: 0) {
                            contentHeader
                        }
                        #endif
                } detail: {
                    detailPane
                }
                #if !os(macOS)
                .searchable(text: $state.searchText, prompt: "Title, author, or text")
                #endif
            }
        }
        // Whatever tries to fold the sidebar away — window restoration,
        // a divider drag to zero — it comes straight back.
        .onChange(of: columnVisibility) {
            if columnVisibility != .all { columnVisibility = .all }
        }
        .fileImporter(isPresented: $showingFolderPicker,
                      allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                state.chooseFolder(url)
            }
        }
        // Document addresses become origamitext:// links in the reader;
        // resolve them in place instead of handing them to the system.
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme?.lowercased() == "origamitext" else { return .systemAction }
            state.open(url: url)
            return .handled
        })
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { state.index.rescan() }
        }
        // Once the library has been read, old folder-style actions
        // migrate into the notes themselves.
        .onChange(of: state.index.isScanning) { _, scanning in
            if !scanning { state.libraryUpkeep() }
        }
        .task { state.libraryUpkeep() }
        // A folder bookmarked while the app could only read needs one
        // fresh pick to write again; ask straight away.
        .task {
            if state.folderNeedsRepick {
                state.showNote("Please choose the library folder again — the saved permission is read-only.")
                showingFolderPicker = true
            }
        }
        #if os(macOS)
        // ESC brings the document into full screen, and takes it out.
        .background {
            Button("") { toggleFullScreen() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .toolbar(isFullScreen ? .hidden : .automatic, for: .windowToolbar)
        // No title over the columns — the window shows only its cards.
        .toolbar(removing: .title)
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.willExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
        #endif
        .overlay(alignment: .bottom) {
            if let note = state.transientNote {
                Text(note)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 3)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: state.transientNote)
        // A theme change repaints the whole window: the colors are read
        // where they are used, so the window rebuilds around them.
        .id(state.theme)
        // The Mac's toolbar stays bare — the title and the sidebar
        // toggle alone, as the layout shows. New Note lives on ⌘N, the
        // folder in Settings ▸ Library, and Find in the options column.
        #if !os(macOS)
        .toolbar {
            ToolbarItem {
                Button {
                    state.newNote()
                } label: {
                    Label("New Note", systemImage: "square.and.pencil")
                }
                .disabled(state.index.folderURL == nil)
                .help("A new note, straight into writing (⌘N)")
            }
            ToolbarItem {
                Menu {
                    if state.parallelDoc != nil {
                        Button("Exit Parallel Reading") { state.exitParallel() }
                        Divider()
                    }
                    ForEach(state.parallelCandidates) { entry in
                        Button(entry.doc.title) { state.enterParallel(with: entry.doc) }
                    }
                } label: {
                    Label("Read in Parallel", systemImage: "rectangle.split.2x1")
                }
                .disabled(state.selectedDoc == nil
                          || (state.parallelCandidates.isEmpty && state.parallelDoc == nil))
                .help("Read a connected document side by side")
            }
            ToolbarItem {
                Menu {
                    Button("Choose Folder…") { showingFolderPicker = true }
                    Button("Rescan") { state.index.rescan() }
                        .disabled(state.index.folderURL == nil)
                    Divider()
                    Toggle("Show Superseded", isOn: $state.showsSuperseded)
                } label: {
                    Label("Library", systemImage: "folder")
                }
            }
        }
        #endif
    }

    #if os(macOS)
    private func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    /// The heading over the notes column: each of the library's places
    /// names its list the way Inbox does — Inbox alone carries the
    /// calendar's reveal triangle.
    @ViewBuilder private var contentHeader: some View {
        switch state.sidebarSelection {
        case .library: listHeader("Inbox")
        case .timeline: timelineHeader
        case .place: listHeader("Places")
        case .people: listHeader("People")
        case .draftLetters: listHeader("Draft Letters")
        case .action(let action): listHeader(action.displayName)
        default: EmptyView()
        }
    }

    /// A plain header naming the list, the Inbox header's quieter twin.
    private func listHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// The heading over the notes column: Timeline as a plain header,
    /// with a separate reveal triangle that opens the calendar. The
    /// chosen span reads beside it while one is set.
    private var timelineHeader: some View {
        HStack(spacing: 6) {
            Text("Timeline")
                .font(.headline)
            Button {
                showingTimelineCalendar = true
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Choose the year, month, or day the list shows")
            if let label = state.timelineRangeLabel {
                Text(label)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .sheet(isPresented: $showingTimelineCalendar) {
            TimelineCalendarSheet()
        }
    }

    /// Find, framed at the foot of the notes list — it narrows the list
    /// to matching title, author, or text — with New Note beside it, the
    /// visible twin of ⌘N now that the toolbar is bare.
    private var findBar: some View {
        @Bindable var state = state
        return HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find", text: $state.searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary))
            Button {
                state.newNote()
            } label: {
                Image(systemName: "square.and.pencil")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(state.index.folderURL == nil)
            .help("New Note (⌘N)")
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        // The strip stands on the same page grey as the list above it,
        // not a system material band of its own.
        .background(AppGreys.page)
    }
    #endif

    // MARK: Columns

    /// Full screen holds the words alone: the open document without the
    /// options column, the sidebar, or the list — an 800-point page,
    /// centered. A note stays its editable self there, and a
    /// whole-library view keeps its canvas.
    @ViewBuilder private var fullScreenPane: some View {
        if let module = LibraryViewRegistry.module(for: state.sidebarSelection),
           let detail = module.makeDetail?(state) {
            detail
        } else if let doc = state.selectedDoc {
            if Self.isWritable(doc) {
                NoteWritingView(doc: doc, measure: 800, centersContent: true)
                    .id(doc.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DocumentReaderView(doc: doc, measure: 800, centersContent: true)
                    .id(doc.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            detailPane
        }
    }

    // MARK: The full-screen sidebar peek

    #if os(macOS)
    /// With nothing open, full screen has nothing to focus on and the
    /// peek is the only way anywhere — so it stays, list unfolded, no
    /// hover gesture required. Opening a document unpins it; a
    /// whole-library view counts as open.
    private var peekIsPinned: Bool {
        state.selectedDoc == nil
            && LibraryViewRegistry.module(for: state.sidebarSelection)?.hidesDocumentList != true
    }

    /// A slim invisible strip along the left edge summons the sidebar as
    /// a floating panel — the gesture the system menu bar teaches at the
    /// top edge — and it fades once the pointer moves on.
    private var peekSidebar: some View {
        HStack(spacing: 0) {
            if showsPeekSidebar || peekIsPinned {
                HStack(spacing: 0) {
                    peekPlacesList
                        .scrollContentBackground(.hidden)
                        .frame(width: 220)
                    if (showsPeekList || peekIsPinned) && peekSelectionHasList {
                        Divider()
                        contentPane
                            .scrollContentBackground(.hidden)
                            .frame(width: 260)
                    }
                }
                .frame(maxHeight: .infinity)
                .background(.regularMaterial)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                                  bottomTrailingRadius: 12, topTrailingRadius: 12))
                .shadow(radius: 8, x: 2, y: 0)
                .background(HoverSensor { inside in
                    inside ? cancelPeekHide() : schedulePeekHide()
                })
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
            HoverSensor { inside in
                if inside {
                    cancelPeekHide()
                    withAnimation(.easeOut(duration: 0.2)) { showsPeekSidebar = true }
                } else {
                    schedulePeekHide()
                }
            }
            .frame(width: 16)
        }
        .frame(maxHeight: .infinity)
        // Opening a note from the peek list hands the room back to it.
        .onChange(of: state.selectedDocID) { dismissPeek() }
    }

    /// The peek's own sidebar: the same places as the split-view
    /// sidebar, but as explicit buttons — every click must answer by
    /// unfolding the contents column.
    private var peekPlacesList: some View {
        List {
            ForEach(SidebarCatalog.sections(filedFolders: state.sidebarFiledFolders),
                    id: \.title) { section in
                Section(section.title) {
                    ForEach(state.shownPlaces(of: section.places)) { place in
                        Button {
                            state.sidebarSelection = place.item
                            revealPeekListIfAvailable()
                        } label: {
                            Label(place.name, systemImage: place.systemImage)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(state.sidebarSelection == place.item
                                      ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
                        )
                    }
                }
            }
        }
    }

    /// Whole-library views have no contents list to unfold; everything
    /// else answers a click with the same list the split view would show.
    private var peekSelectionHasList: Bool {
        LibraryViewRegistry.module(for: state.sidebarSelection)?.hidesDocumentList != true
    }

    private func revealPeekListIfAvailable() {
        guard showsPeekSidebar, peekSelectionHasList else { return }
        withAnimation(.easeOut(duration: 0.2)) { showsPeekList = true }
    }

    private func dismissPeek() {
        guard showsPeekSidebar else { return }
        peekHideTask?.cancel()
        withAnimation(.easeOut(duration: 0.25)) {
            showsPeekSidebar = false
            showsPeekList = false
        }
    }

    /// A short grace period, so the pointer can travel from the edge
    /// strip onto the panel without the panel vanishing under it.
    private func schedulePeekHide() {
        peekHideTask?.cancel()
        peekHideTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                showsPeekSidebar = false
                showsPeekList = false
            }
        }
    }

    private func cancelPeekHide() {
        peekHideTask?.cancel()
    }

    // MARK: The full-screen options peek

    /// The document the full-screen pane is showing, when it is a
    /// document at all — a module's canvas has no options column.
    private var fullScreenDoc: LiquidDoc? {
        if let module = LibraryViewRegistry.module(for: state.sidebarSelection),
           module.makeDetail?(state) != nil { return nil }
        return state.selectedDoc
    }

    /// The sidebar peek's mirror: a slim invisible strip along the
    /// right edge summons the open document's options column as a
    /// floating panel, and it fades once the pointer moves on.
    @ViewBuilder private var peekOptionsColumn: some View {
        if let doc = fullScreenDoc {
            HStack(spacing: 0) {
                HoverSensor { inside in
                    if inside {
                        cancelPeekOptionsHide()
                        withAnimation(.easeOut(duration: 0.2)) { showsPeekOptions = true }
                    } else {
                        schedulePeekOptionsHide()
                    }
                }
                .frame(width: 16)
                if showsPeekOptions {
                    NoteOptionsColumn(doc: doc)
                        .frame(maxHeight: .infinity)
                        .background(.regularMaterial)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12,
                                                          bottomTrailingRadius: 0, topTrailingRadius: 0))
                        .shadow(radius: 8, x: -2, y: 0)
                        .background(HoverSensor { inside in
                            inside ? cancelPeekOptionsHide() : schedulePeekOptionsHide()
                        })
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(maxHeight: .infinity)
            // Moving to another document starts the column hidden again.
            .onChange(of: state.selectedDocID) {
                peekOptionsHideTask?.cancel()
                showsPeekOptions = false
            }
        }
    }

    /// The same grace period as the sidebar peek, so the pointer can
    /// travel from the edge strip onto the column.
    private func schedulePeekOptionsHide() {
        peekOptionsHideTask?.cancel()
        peekOptionsHideTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                showsPeekOptions = false
            }
        }
    }

    private func cancelPeekOptionsHide() {
        peekOptionsHideTask?.cancel()
    }
    #endif

    /// The middle column: a module's content while one is selected, the
    /// document list otherwise.
    @ViewBuilder private var contentPane: some View {
        if state.index.folderURL == nil {
            ContentUnavailableView {
                Label("No Library Folder", systemImage: "folder.badge.questionmark")
            } description: {
                Text("Choose the shared folder of .liquid.json documents.")
            } actions: {
                Button("Choose Folder…") { showingFolderPicker = true }
                    .buttonStyle(.borderedProminent)
            }
        } else if case .view(let id)? = state.sidebarSelection,
                  let module = LibraryViewRegistry.module(id: id) {
            module.makeContent()
        } else if case .filedFolder(let folder)? = state.sidebarSelection {
            DocumentListView(filedUnder: folder)
        } else if state.sidebarSelection == .timeline {
            // Every note, by time, the latest on top.
            DocumentListView()
        } else if state.sidebarSelection == .place {
            DocumentListView(grouping: .place)
        } else if state.sidebarSelection == .people {
            PeopleListView()
        } else if state.sidebarSelection == .draftLetters {
            DocumentListView(draftLettersOnly: true)
        } else if case .action(let action)? = state.sidebarSelection {
            DocumentListView(action: action)
        } else {
            // The Inbox: the reader's notes plus anything unread.
            DocumentListView(inboxOnly: true)
        }
    }

    /// Notes and letters write in place; every other kind reads.
    /// The kinds that are their own writing page — notes and letters.
    /// The document list asks too, for the in-list layout.
    static func isWritable(_ doc: LiquidDoc) -> Bool {
        doc.documentType == LiquidDoc.DocumentType.note.rawValue
            || doc.documentType == LiquidDoc.DocumentType.letter.rawValue
    }

    /// A note — or a letter, a note in every way — is its own writing
    /// space: click and type; it saves itself. Other kinds read
    /// through the reader.
    @ViewBuilder private func notePane(_ doc: LiquidDoc) -> some View {
        if Self.isWritable(doc) {
            NoteWritingView(doc: doc)
                .id(doc.id)
        } else {
            DocumentReaderView(doc: doc)
                .id(doc.id)
        }
    }

    @ViewBuilder private var detailPane: some View {
        if let doc = state.selectedDoc, let parallel = state.parallelDoc {
            ParallelReadingView(leftDoc: doc, rightDoc: parallel)
                .id("\(doc.id)-\(parallel.id)")
        } else if let module = LibraryViewRegistry.module(for: state.sidebarSelection),
                  let detail = module.makeDetail?(state) {
            detail
        } else if let doc = state.selectedDoc {
            // Where the note stands and where its controls go — the
            // reader's choice, made in Settings ▸ Appearance. (In the
            // two-column "In the list" arrangement this pane does not
            // exist; reaching here — a module's list, People, parallel
            // reading — the document opens as in the own-pane layouts.)
            switch state.noteLayout {
            case .controlsUnder:
                VStack(spacing: 0) {
                    notePane(doc)
                    Divider()
                    NoteOptionsColumn(doc: doc, underNote: true)
                }
            default:
                HStack(spacing: 0) {
                    notePane(doc)
                    Divider()
                    NoteOptionsColumn(doc: doc)
                }
            }
        } else if state.sidebarSelection == .people,
                  let listing = state.selectedPersonListing {
            // A clicked person answers with the notes naming them; their
            // contact details live in the People list's disclosure.
            PersonMentionsView(listing: listing)
                .id(listing.id)
        } else if state.index.folderURL == nil {
            ContentUnavailableView {
                Label("No Library Folder", systemImage: "folder.badge.questionmark")
            } description: {
                Text("Choose the shared folder of .liquid.json documents.")
            } actions: {
                Button("Choose Folder…") { showingFolderPicker = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView("No Document Selected",
                                   systemImage: "doc.text",
                                   description: Text("Select a document from the library."))
        }
    }
}

#if os(macOS)
/// The Timeline's calendar: a year of months in a sheet. Click the year
/// at the top to show the whole year, a month's name for that month, or
/// any single day — the notes list narrows to the chosen span. Show
/// Full Timeline clears it.
private struct TimelineCalendarSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var year = Calendar.current.component(.year, from: .now)

    private var calendar: Calendar { Calendar.current }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Button { year -= 1 } label: { Image(systemName: "chevron.left") }
                Spacer()
                Button(String(year)) { chooseYear() }
                    .font(.title3.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .help("Show the whole year")
                Spacer()
                Button { year += 1 } label: { Image(systemName: "chevron.right") }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top),
                                     count: 3),
                      alignment: .leading, spacing: 16) {
                ForEach(1...12, id: \.self) { month in
                    monthCard(month)
                }
            }
            HStack {
                Button("Show Full Timeline") {
                    state.setTimelineRange(nil)
                    dismiss()
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 560)
    }

    private func monthCard(_ month: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(calendar.monthSymbols[month - 1]) { chooseMonth(month) }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .help("Show the whole month")
            let days = daysIn(month)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1),
                                     count: 7), spacing: 1) {
                // Leading blanks put day 1 under its weekday.
                ForEach(0..<leadingBlanks(month), id: \.self) { _ in
                    Text(" ").font(.system(size: 9))
                }
                ForEach(1...days, id: \.self) { day in
                    Button(String(day)) { chooseDay(day, of: month) }
                        .buttonStyle(.plain)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: The spans

    private func chooseYear() {
        guard let start = calendar.date(from: DateComponents(year: year)),
              let next = calendar.date(from: DateComponents(year: year + 1))
        else { return }
        choose(start...(next - 1), label: String(year))
    }

    private func chooseMonth(_ month: Int) {
        guard let start = calendar.date(from: DateComponents(year: year, month: month)),
              let next = calendar.date(byAdding: .month, value: 1, to: start)
        else { return }
        choose(start...(next - 1), label: "\(calendar.monthSymbols[month - 1]) \(year)")
    }

    private func chooseDay(_ day: Int, of month: Int) {
        guard let start = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              let next = calendar.date(byAdding: .day, value: 1, to: start)
        else { return }
        choose(start...(next - 1),
               label: "\(day) \(calendar.monthSymbols[month - 1]) \(year)")
    }

    private func choose(_ range: ClosedRange<Date>, label: String) {
        state.setTimelineRange(range, label: label)
        dismiss()
    }

    // MARK: The month's shape

    private func daysIn(_ month: Int) -> Int {
        guard let start = calendar.date(from: DateComponents(year: year, month: month)),
              let range = calendar.range(of: .day, in: .month, for: start)
        else { return 30 }
        return range.count
    }

    private func leadingBlanks(_ month: Int) -> Int {
        guard let start = calendar.date(from: DateComponents(year: year, month: month))
        else { return 0 }
        let weekday = calendar.component(.weekday, from: start)
        return (weekday - calendar.firstWeekday + 7) % 7
    }
}

/// AppKit-backed hover detection for the full-screen doorway. SwiftUI's
/// `onHover` is unreliable on fully transparent views on macOS —
/// transparent pixels can fall out of hit-testing — and the edge strip
/// must never miss. A real NSTrackingArea is geometric: it fires no
/// matter what is drawn.
private struct HoverSensor: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onChange = onChange
    }

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?

        override func updateTrackingAreas() {
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self, userInfo: nil))
            super.updateTrackingAreas()
        }

        override func mouseEntered(with event: NSEvent) { onChange?(true) }
        override func mouseExited(with event: NSEvent) { onChange?(false) }
    }
}
#endif

/// One document in the library list: the title alone — the list holds
/// the reader's own notes, so author, date, and kind would only repeat
/// themselves. The row dims when the document was retracted.
struct DocumentRow: View {
    @Environment(AppState.self) private var state
    let entry: IndexEntry
    /// A quiet trailing note — the grouping tab's own indication: the
    /// day under Time, the town under Place.
    var detail: String? = nil

    private var isRetracted: Bool { state.index.retractedIDs.contains(entry.id) }

    var body: some View {
        HStack(spacing: 6) {
            Text(entry.doc.title)
                .font(.headline)
                // Bold until read; opening the note ends the bolding.
                .fontWeight(state.isUnread(entry.doc) ? .bold : .regular)
                .lineLimit(2)
            if entry.doc.isSidecar {
                Image(systemName: "paperclip")
                    .foregroundStyle(.secondary)
            }
            if entry.hasDuplicate || entry.doc.hasUnfamiliarFormatVersion {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if isRetracted {
                Text("retracted")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let detail {
                Spacer(minLength: 8)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .opacity(isRetracted ? 0.5 : 1)
        .padding(.vertical, 2)
    }
}

#Preview {
    ContentView()
        .environment(AppState())
}
