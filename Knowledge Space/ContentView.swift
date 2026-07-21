import SwiftUI
import UniformTypeIdentifiers

/// The library window: documents in a sidebar, the reader in the detail
/// column. `origamitext://` links anywhere inside route back through
/// AppState so citations navigate in place.
struct ContentView: View {
    @Environment(AppState.self) private var state
    @Environment(\.scenePhase) private var scenePhase
    #if os(visionOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @State private var showingFolderPicker = false

    var body: some View {
        @Bindable var state = state
        NavigationSplitView {
            sidebar
                .navigationTitle("Knowledge Space")
                .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } detail: {
            if let doc = state.selectedDoc {
                DocumentReaderView(doc: doc)
                    .id(doc.id)
            } else if state.index.folderURL == nil {
                ContentUnavailableView {
                    Label("No Library Folder", systemImage: "folder.badge.questionmark")
                } description: {
                    Text("Choose the shared folder of .origamitext documents.")
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
    }

    // MARK: Sidebar

    private var sidebar: some View {
        @Bindable var state = state
        return List(selection: $state.selectedDocID) {
            Section {
                ForEach(state.listedEntries) { entry in
                    DocumentRow(entry: entry)
                        .tag(entry.id)
                }
            } footer: {
                if state.index.isScanning {
                    Label("Scanning…", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                }
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
            if state.index.folderURL != nil, state.listedEntries.isEmpty,
               !state.index.isScanning {
                ContentUnavailableView("Empty Library",
                                       systemImage: "tray",
                                       description: Text("No .origamitext documents in the folder yet."))
            }
        }
        .toolbar {
            #if os(visionOS)
            ToolbarItem {
                Button {
                    openWindow(id: "knowledge-space")
                } label: {
                    Label("Open Knowledge Space", systemImage: "circle.hexagongrid")
                }
            }
            #endif
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
    }
}

/// One document in the library list: title, credited author, and the
/// listed date, with the row dimmed when the document was retracted.
struct DocumentRow: View {
    @Environment(AppState.self) private var state
    let entry: IndexEntry

    private var isRetracted: Bool { state.index.retractedIDs.contains(entry.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(entry.doc.title)
                    .font(.headline)
                    .lineLimit(2)
                if entry.doc.isSidecar {
                    Image(systemName: "paperclip")
                        .foregroundStyle(.secondary)
                }
                if entry.hasDuplicate || entry.doc.hasUnfamiliarFormatVersion {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            HStack(spacing: 6) {
                Text(entry.doc.displayAuthor)
                Text("·")
                Text(entry.doc.listedDateText)
                if let type = entry.doc.documentType {
                    Text(type)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                if isRetracted {
                    Text("retracted")
                        .foregroundStyle(.red)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .opacity(isRetracted ? 0.5 : 1)
        .padding(.vertical, 2)
    }
}

#Preview {
    ContentView()
        .environment(AppState())
}
