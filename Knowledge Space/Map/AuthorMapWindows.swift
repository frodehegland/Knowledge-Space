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
                }
            }
        }
        .padding()
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: openableTypes,
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                state.open(url: url)
            }
        }
        .onAppear {
            state.reopenLastDocument()
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
                Text("No documents (.liquid.json) here yet. If the folder is in iCloud, its contents may still be downloading.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Check Again") { state.rescanFolder() }
            } else {
                Button("Show Folder Map") { state.showFolderMap() }
                    .buttonStyle(.borderedProminent)

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
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    @State private var showingAgentPanel = false

    // The original toolbar's sort switches, under their original keys.
    @AppStorage("sort_reverse") private var sortReverse = false
    @AppStorage("sort_time_reverse") private var sortTimeReverse = false

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
    }

    private var controlsBar: some View {
        HStack(spacing: 10) {
            Button {
                openWindow(id: "Library")
            } label: {
                Label("Library", systemImage: "books.vertical")
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
            if !state.showingFolderMap {
                Button("Show Folder Map") { state.showFolderMap() }
                Divider()
            }
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

/// The Settings panel, toggled from the right-wrist bangle.
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

    var body: some View {
        TabView {
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
        }
        .frame(minWidth: 480, minHeight: 380)
        .onAppear { state.isSettingsWindowOpen = true }
        .onDisappear { state.isSettingsWindowOpen = false }
    }
}
#endif
