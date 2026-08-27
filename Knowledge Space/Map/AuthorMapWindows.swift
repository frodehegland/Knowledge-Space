//
//  AuthorMapWindows.swift
//  Knowledge Space
//
//  The Map's two windows, shaped like the original Author visionOS app:
//  the Library window is the way in (open the community folder or a
//  document, step into the map), and the Map Controls window is the
//  control bar — floating free of the map itself, left wherever the
//  hand puts it, carrying the original toolbar's command set.
//

#if os(visionOS)
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Library

/// The way in, mirroring the original app's Documents browser window:
/// choose the community folder or a document, and the map opens in
/// space with the controls alongside while this window steps aside.
struct MapLibraryView: View {
    @Environment(AuthorMapState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    @State private var showingImporter = false

    var body: some View {
        Group {
            if state.folderURL != nil {
                folderList
            } else {
                ContentUnavailableView {
                    Label("Author Map", systemImage: "circle.hexagongrid")
                } description: {
                    if let error = state.lastError {
                        Text(error)
                    } else {
                        Text("Open your community folder — or a single document (.liquid.json) — to see its Map in space.")
                    }
                } actions: {
                    Button("Open Folder or Document…") { showingImporter = true }
                    #if targetEnvironment(simulator)
                    // The demo weave, reachable without a folder.
                    Button("Sphere Weave (Demo)") {
                        Task { @MainActor in
                            if !state.isWeaveSpaceOpen {
                                _ = await openImmersiveSpace(id: "SphereWeaveSpace")
                            }
                            openWindow(id: "SphereWeaveControls")
                        }
                    }
                    #endif
                }
            }
        }
        .padding()
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: openableTypes,
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { state.open(url: url) }
            case .failure(let error):
                // Never fail into silence: the picker's reason lands
                // where the window already shows errors.
                state.lastError = "Could not open the selection: \(error.localizedDescription)"
            }
        }
        .onAppear {
            state.reopenLastDocument()
            #if targetEnvironment(simulator)
            // Walk straight into the demo weave: the simulator has no
            // community folder, and this is where the weave is tuned.
            if state.folderURL == nil {
                Task { @MainActor in
                    if !state.isWeaveSpaceOpen {
                        _ = await openImmersiveSpace(id: "SphereWeaveSpace")
                    }
                }
            }
            #endif
        }
        .onChange(of: state.loadCount) {
            enterMap()
        }
    }

    /// Opens the map scenes the way the original did: toolbar window,
    /// immersive space, and the browser steps aside.
    private func enterMap() {
        guard state.loadCount > 0 else { return }
        Task { @MainActor in
            openWindow(id: "MapControls")
            if !state.isMapSpaceOpen {
                _ = await openImmersiveSpace(id: "MapSpace")
            }
            dismissWindow(id: "Library")
        }
    }

    /// The folder's documents, listed until one is opened.
    private var folderList: some View {
        VStack(spacing: 14) {
            Label(state.folderURL?.lastPathComponent ?? "Folder", systemImage: "folder")
                .font(.title3)

            if let error = state.lastError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            if state.folderDocuments.isEmpty {
                if state.folderScanRunning {
                    ProgressView()
                    Text("Reading the folder…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if state.pendingDownloadCount > 0 {
                    // First visit on this device: the folder is all
                    // iCloud placeholders. The scan keeps itself going
                    // and the map opens when the documents land.
                    ProgressView()
                    Text("Downloading \(state.pendingDownloadCount) document\(state.pendingDownloadCount == 1 ? "" : "s") from iCloud — the map opens when they arrive.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("No documents (.liquid.json) here yet. If the folder is in iCloud, its contents may still be downloading.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button("Check Again") { state.rescanFolder() }
            } else {
                Button("Show Folder Map") { state.showFolderMap() }
                    .buttonStyle(.borderedProminent)

                if state.pendingDownloadCount > 0 {
                    Text("\(state.pendingDownloadCount) more still downloading from iCloud…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Room-scale flexible space: all documents float free in
                // the room, draggable to any position, reading the same
                // .liquid.json format as the macOS app.
                Button {
                    Task { @MainActor in
                        if state.isMapSpaceOpen {
                            if state.hasUnsavedChanges { state.save() }
                            await dismissImmersiveSpace()
                        } else if state.isWeaveSpaceOpen {
                            await dismissImmersiveSpace()
                        }
                        if !state.isFlexSpaceOpen {
                            _ = await openImmersiveSpace(id: "FlexibleRoomSpace")
                        }
                        openWindow(id: "FlexSpaceControls")
                        dismissWindow(id: "Library")
                    }
                } label: {
                    Label("Room Space", systemImage: "rectangle.3.group")
                }
                .buttonStyle(.borderedProminent)

                // The library in the round, filling the room. The
                // folder map steps aside (saved first) — one immersive
                // space at a time — and the browser steps aside too,
                // the way it does for the map.
                Button {
                    Task { @MainActor in
                        if state.isMapSpaceOpen {
                            if state.hasUnsavedChanges { state.save() }
                            await dismissImmersiveSpace()
                        } else if state.isFlexSpaceOpen {
                            await dismissImmersiveSpace()
                        }
                        if !state.isWeaveSpaceOpen {
                            _ = await openImmersiveSpace(id: "SphereWeaveSpace")
                        }
                        openWindow(id: "SphereWeaveControls")
                        dismissWindow(id: "Library")
                    }
                } label: {
                    Label("Sphere Weave", systemImage: "globe")
                }

                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(state.folderDocuments) { document in
                            Button {
                                state.openDocument(url: document.url)
                            } label: {
                                Text(document.title)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }

            Button("Choose Another Folder…") { showingImporter = true }
                .buttonStyle(.borderless)
                .font(.callout)
        }
    }

    private var openableTypes: [UTType] {
        // Documents are plain `.liquid.json` files, so `.json` is the type
        // that makes them selectable; the `.liquid` package and folders
        // remain openable for older documents.
        var types: [UTType] = [.json, .package, .folder]
        if let liquid = UTType(filenameExtension: "liquid", conformingTo: .package) {
            types.insert(liquid, at: 0)
        }
        return types
    }
}

// MARK: - Controls

/// The control bar in its own single-instance window — the original's
/// Map Toolbar, command for command where the engine can express it:
/// Focus, Select, Open/Close, Show, Layout, Views, Node(s). The
/// assistant unfolds beneath it.
struct MapControlsView: View {
    @Environment(AuthorMapState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    @State private var showingAgentPanel = false

    // The original toolbar's sort switches, under their original keys.
    @AppStorage("sort_reverse") private var sortReverse = false
    @AppStorage("sort_time_reverse") private var sortTimeReverse = false

    // Handing a node's external file to another app: try the Reader
    // scheme, fall back to the system share sheet. The scheme is the
    // reader's own, editable in Settings.
    @Environment(\.openURL) private var openURL
    @AppStorage("readerURLScheme") private var readerURLScheme = ReaderHandoff.defaultScheme
    @State private var shareRequest: ExternalOpenRequest?

    private var hasSelection: Bool { !state.engine.selection.isEmpty }

    private var selectedIDs: [FlowNodeIdentifier] { Array(state.engine.selection) }

    private var hiddenIDs: [FlowNodeIdentifier] {
        state.engine.document.nodes.filter { $0.isHidden }.map { $0.identifier }
    }

    var body: some View {
        let _ = state.revision
        VStack(spacing: 12) {
            // The bar keeps its ideal width — the window (sized to
            // content) grows with it rather than squeezing the text.
            controlsBar
                .fixedSize(horizontal: true, vertical: false)
            if showingAgentPanel {
                AuthorMapAgentPanel(state: state)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(minWidth: 900)
        .onAppear {
            state.isControlsWindowOpen = true
            state.controlsToggledOff = false
        }
        .onDisappear {
            state.isControlsWindowOpen = false
            // The toolbar cannot be closed away from an open map: unless
            // the left bangle asked for this, it comes straight back.
            if state.isMapSpaceOpen && !state.controlsToggledOff {
                openWindow(id: "MapControls")
            }
        }
        // A node asked to open its external file: this window is a plain
        // window and can host the handoff the immersive space cannot.
        .onChange(of: state.externalOpenRequest) { _, request in
            handleExternalOpen(request)
        }
        .sheet(item: $shareRequest) { request in
            ShareSheet(url: request.url)
        }
    }

    /// Tries the Reader scheme first; if no app answers, the file goes to
    /// the system share sheet so it can still reach another reader.
    private func handleExternalOpen(_ request: ExternalOpenRequest?) {
        guard let request else { return }
        state.externalOpenRequest = nil
        if let schemeURL = ReaderHandoff.schemeURL(forFileAt: request.url, template: readerURLScheme) {
            openURL(schemeURL) { accepted in
                if !accepted { shareRequest = ExternalOpenRequest(url: request.url) }
            }
        } else {
            shareRequest = ExternalOpenRequest(url: request.url)
        }
    }

    private var controlsBar: some View {
        HStack(spacing: 10) {
            Button {
                openWindow(id: "Library")
            } label: {
                Label("Library", systemImage: "books.vertical")
            }

            // Step back out of a document opened by drilling into a link.
            if state.canGoBack {
                Button {
                    state.goBack()
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
            }

            // Write a new note into the community folder.
            if state.folderURL != nil {
                Button {
                    state.prepareNewNote()
                    openWindow(id: "MapNoteEditor")
                } label: {
                    Label("New Note", systemImage: "square.and.pencil")
                }
            }

            if state.documentURL != nil || state.showingFolderMap {
                Text(state.documentTitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                focusButton

                // The original's [D]: everything let go at once.
                Button("[D]") { state.run(.deselectAll) }
                    .disabled(!hasSelection)

                selectMenu
                openCloseButton
                showMenu

                // The original's [A]: everything comes back.
                Button("[A]") { showEverything() }

                layoutMenu
                viewsMenu

                if hasSelection {
                    nodeMenu
                }

                Button {
                    state.run(.setSelection(ids: []))
                    if state.engine.canUndo {
                        try? state.engine.undo()
                    }
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!state.engine.canUndo)
                .labelStyle(.iconOnly)

                Button {
                    state.save()
                } label: {
                    Label("Save", systemImage: state.hasUnsavedChanges ? "circle.fill" : "checkmark.circle")
                }
                .labelStyle(.iconOnly)

                Button {
                    showingAgentPanel.toggle()
                } label: {
                    Label("Assistant", systemImage: "sparkles")
                }
                .labelStyle(.iconOnly)
            }

            if !state.folderDocuments.isEmpty {
                documentsMenu
            }

            // Introduction & Settings — the panel the right-wrist bangle
            // used to open, now reachable from the bar itself.
            Button {
                openWindow(id: "MapSettings")
            } label: {
                Label("Introduction & Settings", systemImage: "info.circle")
            }
            .labelStyle(.iconOnly)

            // Prototype: extend a flat portrait into a 3D spatial scene.
            Button {
                openWindow(id: "PortraitPrototype")
            } label: {
                Label("Portrait 3D", systemImage: "cube.transparent")
            }
            .labelStyle(.iconOnly)

            Button {
                Task { @MainActor in
                    if state.isMapSpaceOpen {
                        if state.hasUnsavedChanges { state.save() }
                        await dismissImmersiveSpace()
                    }
                    if !state.isFlexSpaceOpen {
                        _ = await openImmersiveSpace(id: "FlexibleRoomSpace")
                    }
                    openWindow(id: "FlexSpaceControls")
                }
            } label: {
                Label("Room Space", systemImage: "rectangle.3.group")
            }
            .labelStyle(.iconOnly)

            Button {
                Task { @MainActor in
                    if state.isMapSpaceOpen {
                        if state.hasUnsavedChanges { state.save() }
                        await dismissImmersiveSpace()
                    } else if state.isFlexSpaceOpen {
                        await dismissImmersiveSpace()
                    }
                    if !state.isWeaveSpaceOpen {
                        _ = await openImmersiveSpace(id: "SphereWeaveSpace")
                    }
                    openWindow(id: "SphereWeaveControls")
                }
            } label: {
                Label("Sphere Weave", systemImage: "globe")
            }
            .labelStyle(.iconOnly)

            Button {
                Task { @MainActor in
                    if state.hasUnsavedChanges { state.save() }
                    await dismissImmersiveSpace()
                    openWindow(id: "Library")
                }
            } label: {
                Label("Close Map", systemImage: "xmark.circle")
            }
            .labelStyle(.iconOnly)
        }
    }

    // MARK: - Focus

    private var focusButton: some View {
        Button(state.isFocused ? "Un-Focus" : "Focus") {
            state.toggleFocus()
        }
        .disabled(!state.isFocused && !hasSelection)
    }

    // MARK: - Select (the original menu, tag for tag)

    private func select(_ criteria: MapCriteria) {
        state.run(.selectByCriteria(criteria: criteria, extending: false))
    }

    private var selectIgnoreContext: Binding<Bool> {
        Binding { state.engine.selectIgnoreContext }
            set: { state.run(.setSelectIgnoreContext($0)) }
    }

    private var showIgnoreContext: Binding<Bool> {
        Binding { state.engine.showIgnoreContext }
            set: { state.run(.setShowIgnoreContext($0)) }
    }

    private var selectMenu: some View {
        Menu {
            Button("Citations") { select(MapCriteria(nodeTypes: [.citation])) }
            Button("Notes") { select(MapCriteria(nodeTypes: [.note])) }
            Button("Concepts") { select(MapCriteria(tagIdentifiers: ["concept"])) }
            Button("Sections") { select(MapCriteria(tagIdentifiers: ["section"])) }

            Divider()

            Menu("Label") {
                Button("Title") { select(MapCriteria(tagIdentifiers: ["title"])) }
                Button("Label") { select(MapCriteria(tagIdentifiers: ["label"])) }
            }

            Menu("Context") {
                Button("Snap Back") { snapBackSelection() }
                Toggle("Ignore Context", isOn: selectIgnoreContext)
                Button("Context") { select(MapCriteria(isContext: true)) }
            }

            Menu("Document") {
                Button("Map") { select(MapCriteria(tagIdentifiers: ["map"])) }
                Button("Document") { select(MapCriteria(tagIdentifiers: ["document"])) }
                Button("Quote") { select(MapCriteria(tagIdentifiers: ["quote"])) }
            }

            Menu("Issues") {
                Button("Done") { select(MapCriteria(tagIdentifiers: ["done"])) }
                Button("Marked") { select(MapCriteria(tagIdentifiers: ["marked"])) }
                Button("In Progress") { select(MapCriteria(tagIdentifiers: ["in progress"])) }
                Button("Issue") { select(MapCriteria(tagIdentifiers: ["issue"])) }
            }

            Menu("Category") {
                Button("Product") { select(MapCriteria(tagIdentifiers: ["product"])) }
                Button("Event") { select(MapCriteria(tagIdentifiers: ["event"])) }
                Button("Institution") { select(MapCriteria(tagIdentifiers: ["institution"])) }
                Button("Location") { select(MapCriteria(tagIdentifiers: ["location"])) }
                Button("Person") { select(MapCriteria(tagIdentifiers: ["person"])) }
                Divider()
                Button("Concept") { select(MapCriteria(tagIdentifiers: ["concept"])) }
            }

            Divider()

            Button("Similar") { state.run(.selectSimilar) }
            Button("Connected") { state.run(.selectConnected) }
            Button("Liked") { select(MapCriteria(isLiked: true)) }
            Button("All") { state.run(.selectAll) }
        } label: {
            Text("Select")
        }
    }

    /// The original Context > Snap Back: the selection returns to the
    /// map plane (z = 0).
    private func snapBackSelection() {
        var positions: [FlowNodeIdentifier: NodePosition] = [:]
        for id in state.engine.selection {
            let p = state.engine.position(of: id)
            positions[id] = NodePosition(x: p.x, y: p.y, z: 0)
        }
        state.run(.move(positions: positions))
    }

    // MARK: - Open / Close (expansion, the original's open state)

    private var openCloseButton: some View {
        let anyOpen = !state.expandedNodes.isDisjoint(with: state.engine.selection)
        return Button(anyOpen ? "Close" : "Open") {
            state.setExpanded(selectedIDs, !anyOpen)
        }
        .disabled(!hasSelection)
    }

    // MARK: - Show (the original menu on the engine's filters)

    private func show(_ filter: MapShowFilter) {
        state.run(.setShowFilter(filter))
    }

    private var showMenu: some View {
        Menu {
            Button("Citations") { state.run(.setVisibilityMode(.showOnlyCitations)) }
            Button("Notes") { state.run(.setVisibilityMode(.showOnlyNotes)) }
            Button("Concepts") { state.run(.setVisibilityMode(.showOnlyConcepts)) }
            Button("Concepts and Citations") { state.run(.setVisibilityMode(.showConceptsAndCitations)) }
            Button("Everything") { state.run(.setVisibilityMode(.showAll)) }

            Divider()

            Menu("Label") {
                Button("Title") { show(.tag("title")) }
                Button("Label") { show(.tag("label")) }
            }

            Menu("Context") {
                Toggle("Ignore Context", isOn: showIgnoreContext)
                Button("Context") { show(.context) }
            }

            Menu("Document") {
                Button("Map") { show(.tag("map")) }
                Button("Document") { show(.tag("document")) }
                Button("Quote") { show(.tag("quote")) }
            }

            Menu("Issues") {
                Button("Done") { show(.tag("done")) }
                Button("Marked") { show(.tag("marked")) }
                Button("In Progress") { show(.tag("in progress")) }
                Button("Issue") { show(.tag("issue")) }
            }

            Menu("Category") {
                Button("Product") { show(.tag("product")) }
                Button("Event") { show(.tag("event")) }
                Button("Institution") { show(.tag("institution")) }
                Button("Location") { show(.tag("location")) }
                Button("Person") { show(.tag("person")) }
                Divider()
                Button("Concept") { show(.tag("concept")) }
            }

            Button("Liked") { show(.liked(true)) }
            Button("Clear Filter") { show(.none) }

            Divider()

            Button("Close All") { state.collapseAll() }

            Divider()

            if !hiddenIDs.isEmpty {
                Button("Show All") { showEverything() }
            }
            if hasSelection {
                Button("Hide") { state.run(.hide(ids: selectedIDs)) }
            }
        } label: {
            Text("Show")
        }
    }

    /// The original's showAll: hidden cards return and filters clear.
    private func showEverything() {
        let hidden = hiddenIDs
        if !hidden.isEmpty {
            state.run(.unhide(ids: hidden))
        }
        state.run(.setShowFilter(.none))
        state.run(.setVisibilityMode(.showAll))
    }

    // MARK: - Layout (the original's Distribute and Align)

    private func distribute(_ axis: MapAxis, _ sort: MapDistributionSort, _ style: MapDistributionStyle) {
        state.run(.distribute(axis: axis, sort: sort, style: style))
    }

    private var layoutMenu: some View {
        Menu {
            Menu("Distribute") {
                Menu("By Time") {
                    Toggle("Reverse", isOn: $sortTimeReverse)
                    Divider()
                    Button("Depth Long") { distribute(.z, sortTimeReverse ? .timeReverse : .time, .spacing) }
                    Button("Depth") { distribute(.z, sortTimeReverse ? .timeReverse : .time, .evenly) }
                    Button("Vertical") { distribute(.y, sortTimeReverse ? .timeReverse : .time, .spacing) }
                    Button("Horizontal") { distribute(.x, sortTimeReverse ? .timeReverse : .time, .spacing) }
                }
                Divider()
                Toggle("Reverse", isOn: $sortReverse)
                Button("Depth Long") { distribute(.z, sortReverse ? .reverse : .alphabetic, .spacing) }
                Button("Depth") { distribute(.z, sortReverse ? .reverse : .alphabetic, .evenly) }
                Button("Vertical") { distribute(.y, sortReverse ? .reverse : .alphabetic, .spacing) }
                Button("Horizontal") { distribute(.x, sortReverse ? .reverse : .alphabetic, .spacing) }
                Divider()
                Button("Evenly Horizontal") { distribute(.x, .standard, .evenly) }
                Button("Evenly Vertical") { distribute(.y, .standard, .evenly) }
                Button("Evenly in Depth") { distribute(.z, .standard, .evenly) }
            }

            Menu("Align") {
                Button("Depth") { state.run(.align(axis: .z, alignment: .center)) }
                Button {
                    state.run(.align(axis: .x, alignment: .maxEdge))
                } label: {
                    Label("Right", systemImage: "align.horizontal.right")
                }
                Button {
                    state.run(.align(axis: .x, alignment: .center))
                } label: {
                    Label("Center", systemImage: "align.horizontal.center")
                }
                Button {
                    state.run(.align(axis: .x, alignment: .minEdge))
                } label: {
                    Label("Left", systemImage: "align.horizontal.left")
                }
                Divider()
                Button("Top Edges") { state.run(.align(axis: .y, alignment: .minEdge)) }
                Button("Vertical Centers") { state.run(.align(axis: .y, alignment: .center)) }
                Button("Bottom Edges") { state.run(.align(axis: .y, alignment: .maxEdge)) }
            }

            Divider()

            Button("Flatten to Plane") {
                var positions: [FlowNodeIdentifier: NodePosition] = [:]
                for node in state.engine.document.nodes {
                    let p = state.engine.position(of: node.identifier)
                    positions[node.identifier] = NodePosition(x: p.x, y: p.y, z: 0)
                }
                state.run(.move(positions: positions))
            }
            Button("Recenter Map") { state.recenter() }
        } label: {
            Text("Layout")
        }
    }

    // MARK: - Views (the document's remembered arrangements)

    private var viewsMenu: some View {
        Menu {
            Button("+ New View") {
                state.run(.saveCustomLayout(name: Self.newViewName()))
            }

            if !state.engine.document.customLayouts.isEmpty {
                Divider()
                ForEach(state.engine.document.customLayouts, id: \.id) { layout in
                    Button(layout.name) { state.run(.applyCustomLayout(id: layout.id)) }
                }
                Divider()
                Menu("Delete View") {
                    ForEach(state.engine.document.customLayouts, id: \.id) { layout in
                        Button(layout.name, role: .destructive) {
                            state.run(.deleteCustomLayout(id: layout.id))
                        }
                    }
                }
            }
        } label: {
            Text("Views")
        }
    }

    private static func newViewName() -> String {
        "View " + Date.now.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Node(s) (the selection's own menu)

    private var nodeMenu: some View {
        Menu {
            Button("Hide") { state.run(.hide(ids: selectedIDs)) }
            if !hiddenIDs.isEmpty {
                Button("Un-Hide") { state.run(.unhide(ids: hiddenIDs)) }
            }
            Divider()
            Button("Like") { state.run(.setLiked(ids: selectedIDs, value: true)) }
            Button("Un-Like") { state.run(.setLiked(ids: selectedIDs, value: false)) }
            Button("Select Liked") { select(MapCriteria(isLiked: true)) }
            Divider()
            Button("Mark as Context") { state.run(.setContext(ids: selectedIDs, value: true)) }
            Button("Unmark Context") { state.run(.setContext(ids: selectedIDs, value: false)) }
        } label: {
            Text(state.engine.selection.count > 1 ? "Nodes" : "Node")
        }
    }

    // MARK: - Documents

    private var documentsMenu: some View {
        Menu {
            // The library cuts — each shown alone as its own map — with
            // the whole folder above them. (These were the left-arm menu.)
            Button {
                state.showFolderMap()
            } label: {
                Label("Whole Folder", systemImage: "square.grid.2x2")
            }
            ForEach(MapLibraryCategory.allCases) { category in
                Button {
                    state.showCategory(category)
                } label: {
                    Label(category.title, systemImage: category.systemImage)
                }
            }
            Divider()
            ForEach(state.folderDocuments) { document in
                Button(document.title) { state.openDocument(url: document.url) }
            }
            Divider()
            Button("Rescan Folder") { state.rescanFolder() }
        } label: {
            Label("Documents", systemImage: "doc.text")
                .labelStyle(.iconOnly)
        }
    }
}

// MARK: - Settings

/// The Introduction & Settings panel, opened from the control bar.
struct MapSettingsView: View {
    @Environment(AuthorMapState.self) private var state

    @AppStorage("nodeBorderVisible") private var nodeBorderVisible = true
    @AppStorage("nodeMaxCharsClosed") private var nodeMaxCharsClosed = 30
    @AppStorage("nodeMaxCharsOpen") private var nodeMaxCharsOpen = 45
    @AppStorage("nodeOpaqueWhenOpen") private var nodeOpaqueWhenOpen = true
    @AppStorage("nodeOpaqueWhenSelected") private var nodeOpaqueWhenSelected = true
    @AppStorage("nodeBillboarding") private var nodeBillboarding = true
    // The toolbar's original key — the same setting, reachable here.
    @AppStorage("onlySelectedNodesCanMove") private var onlySelectedNodesCanMove = true

    // The Reader handoff: where Reader's files live, and the scheme that
    // opens one there.
    @AppStorage("readerURLScheme") private var readerURLScheme = ReaderHandoff.defaultScheme
    @State private var showingReaderImporter = false

    var body: some View {
        TabView {
            Tab("Introduction", systemImage: "info.circle") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Knowledge Space")
                            .font(.title2.weight(.semibold))
                        Text(verbatim: "Your community's documents as a space you stand inside. The left wrist opens the library — Thoughts, Journal, and Articles, each shown on its own, or the whole folder — and the toolbar. This right wrist holds the introduction and settings.")
                            .foregroundStyle(.secondary)
                        Text(verbatim: "Double-tap a card to open it; an open card can follow a link inward or hand a wrapped PDF to your reader. The Reader library and its open-in scheme live in the Library tab.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
            }

            Tab("Appearance", systemImage: "paintbrush") {
                Form {
                    Section("Nodes") {
                        Toggle("Node Border", isOn: $nodeBorderVisible)
                        Toggle("Opaque When Open", isOn: $nodeOpaqueWhenOpen)
                        Toggle("Opaque When Selected", isOn: $nodeOpaqueWhenSelected)
                        Toggle("Billboarding", isOn: $nodeBillboarding)
                        Stepper("Max Characters Wide, Closed: \(nodeMaxCharsClosed)",
                                value: $nodeMaxCharsClosed, in: 10...80, step: 5)
                        Stepper("Max Characters Wide, Open: \(nodeMaxCharsOpen)",
                                value: $nodeMaxCharsOpen, in: 20...120, step: 5)
                        Toggle("Only Move When Selected", isOn: $onlySelectedNodesCanMove)
                    }
                }
            }

            Tab("Library", systemImage: "books.vertical") {
                Form {
                    Section("Reader Library") {
                        LabeledContent("Folder",
                                       value: state.readerLibraryURL?.lastPathComponent ?? "Not chosen")
                        Button("Choose Reader Library…") { showingReaderImporter = true }
                        Text(verbatim: "Where Reader keeps its files. A node's external file — a PDF above all — is found here when it is not in the community folder.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Section("Open in Reader") {
                        TextField("URL Scheme", text: $readerURLScheme)
                        Text(verbatim: "How an external file is handed to Reader. <file> becomes the file's path. If no app answers the scheme, the system share sheet opens instead.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 380)
        .fileImporter(isPresented: $showingReaderImporter,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                state.chooseReaderLibrary(url: url)
            }
        }
        .onAppear { state.isSettingsWindowOpen = true }
        .onDisappear { state.isSettingsWindowOpen = false }
    }
}

// MARK: - Note editor

/// Writing a note in space: title and body, its kind (Note, Journal, or
/// Thought — the kinds the library's own views gather), and its action
/// standing. New when the editor was opened for a fresh note, an edit
/// when a card asked to change one. Saving writes the JSON into the
/// community folder and the map refreshes to show it.
struct MapNoteEditorView: View {
    @Environment(AuthorMapState.self) private var state
    @Environment(\.dismissWindow) private var dismissWindow

    /// The note kinds this editor writes: the own-hand kinds the Map's
    /// left-arm menu gathers. Raw values are the documentType tokens.
    private enum NoteKind: String, CaseIterable, Identifiable {
        case note, journal, thought
        var id: String { rawValue }
        var label: String {
            switch self {
            case .note: "Note"
            case .journal: "Journal"
            case .thought: "Thought"
            }
        }
    }

    @State private var title = ""
    @State private var bodyText = ""
    @State private var author = ""
    @State private var kind: NoteKind = .note
    @State private var action: LiquidDoc.Action?
    @State private var loaded = false

    private var isNew: Bool { state.noteBeingEdited == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New Note" : "Edit Note")
                .font(.title2.weight(.semibold))

            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $bodyText)
                .frame(minHeight: 200)
                .padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

            // Only asked for when the folder has no author name yet — a
            // note must carry one, per the format.
            if state.authorName.trimmingCharacters(in: .whitespaces).isEmpty {
                TextField("Your name", text: $author)
                    .textFieldStyle(.roundedBorder)
            }

            Picker("Kind", selection: $kind) {
                ForEach(NoteKind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            // The action standing — its own axis, independent of the kind.
            Picker("Action", selection: $action) {
                Text("None").tag(LiquidDoc.Action?.none)
                ForEach(LiquidDoc.Action.allCases, id: \.self) { standing in
                    Text(standing.displayName).tag(LiquidDoc.Action?.some(standing))
                }
            }

            if let error = state.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") { dismissWindow(id: "MapNoteEditor") }
                Spacer()
                Button("Save") {
                    if state.saveNote(title: title, bodyText: bodyText,
                                      author: author, kind: kind.rawValue,
                                      action: action) {
                        dismissWindow(id: "MapNoteEditor")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty
                          && bodyText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 440)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            author = state.authorName
            if let doc = state.noteBeingEdited {
                title = doc.title == "Untitled" ? "" : doc.title
                bodyText = doc.bodyEditingText
                kind = NoteKind(rawValue: doc.documentType ?? "note") ?? .note
                action = doc.actionValue
            }
        }
    }
}
#endif
