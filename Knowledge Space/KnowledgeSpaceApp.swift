import SwiftUI

/// Knowledge Space: a reader for Origami Documents (`.liquid.json`) —
/// the community-folder library presented as a browsable, linked space.
/// The document format and its data structures are shared with Origami
/// Text (see OrigamiText/ORIGAMI-DOCUMENT-FORMAT.md).
///
/// On visionOS the app *is* the Map, structured like the original Author
/// visionOS app: a Library window as the way in, a control bar in its own
/// free-floating window, and the map itself an immersive space whose
/// cards hang anywhere in the room — backed by the same `.liquid.json`
/// files.
@main
struct KnowledgeSpaceApp: App {
    #if os(visionOS)
    @State private var mapState = AuthorMapState()
    #else
    @State private var state = AppState()
    #endif

    var body: some Scene {
        #if os(visionOS)
        // The way in: open the community folder or a document here, and
        // the map opens in space while this window steps aside.
        WindowGroup(id: "Library") {
            MapLibraryView()
                .environment(mapState)
        }
        .defaultSize(width: 520, height: 640)

        // The control bar — a single-instance window (reopening brings
        // the existing one forward), moved independently of the map.
        Window("Map Controls", id: "MapControls") {
            MapControlsView()
                .environment(mapState)
        }
        .windowResizability(.contentSize)
        // visionOS offers no meter-based placement; the utility-panel
        // position is the near one — down in front of the viewer, well
        // in front of where the map hangs (1.4 m out).
        .defaultWindowPlacement { _, _ in
            WindowPlacement(.utilityPanel)
        }

        // Settings, toggled from the right-wrist bangle. No options
        // live here yet; the panel is the place they will go.
        Window("Settings", id: "MapSettings") {
            MapSettingsView()
                .environment(mapState)
        }
        .windowResizability(.contentSize)
        .defaultWindowPlacement { _, _ in
            WindowPlacement(.utilityPanel)
        }

        // The Map itself: cards free in the room, nothing framing them.
        ImmersiveSpace(id: "MapSpace") {
            AuthorMapSpaceView()
                .environment(mapState)
        }
        #else
        WindowGroup {
            ContentView()
                .environment(state)
        }
        // ⌘N is a new note — the core act — displacing New Window.
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") {
                    state.newNote()
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(state.index.folderURL == nil)
            }
            // Old-name documents (.origamitext) come home by conversion —
            // the same JSON, renamed to .liquid.json in the library folder.
            CommandGroup(after: .newItem) {
                Button("Convert Old Documents…") {
                    state.importLegacyDocuments()
                }
                .disabled(state.index.folderURL == nil)
            }
        }

        Settings {
            SettingsView()
                .environment(state)
        }
        #endif
    }
}
