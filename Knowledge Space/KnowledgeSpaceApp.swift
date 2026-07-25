import SwiftUI

/// Knowledge Space: a reader for Origami Documents (`.liquid.json`) —
/// the community-folder library presented as a browsable, linked space.
/// The document format and its data structures are shared with Origami
/// Text (see OrigamiText/ORIGAMI-DOCUMENT-FORMAT.md).
///
/// On visionOS the app *is* the Map: one volumetric window showing the
/// open document's concept map, backed by the same `.liquid.json` files.
@main
struct KnowledgeSpaceApp: App {
    #if !os(visionOS)
    @State private var state = AppState()
    #endif

    var body: some Scene {
        #if os(visionOS)
        // The Map as a volume: the document's concept map with an AI
        // assistant that works the map alongside the hand.
        WindowGroup {
            AuthorMapSpaceView()
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 1.7, height: 1.1, depth: 0.7, in: .meters)
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
