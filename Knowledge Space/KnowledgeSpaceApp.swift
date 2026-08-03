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
#if os(macOS)
/// Catches files handed to the app itself — an email dropped on the
/// Dock icon, or an .eml opened with Knowledge Space — and turns each
/// into a document. ContentView points `state` here on appearance.
final class MailOpenDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var state: AppState?

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            Self.state?.handleEmailFiles(urls)
        }
    }
}
#endif

@main
struct KnowledgeSpaceApp: App {
    #if os(visionOS)
    @State private var mapState = AuthorMapState()
    #else
    @State private var state = AppState()
    @NSApplicationDelegateAdaptor(MailOpenDelegate.self) private var mailOpenDelegate
    #endif

    var body: some Scene {
        #if os(visionOS)
        // The way in: open the community folder or a document here, and
        // the map opens in space while this window steps aside.
        WindowGroup(id: "Library") {
            MapLibraryView()
                .environment(mapState)
                .modifier(KSWidgetDeepLink())
        }
        .defaultSize(width: 520, height: 640)

        // The window a widget opens into: a tall framed list of To Do or
        // Journal — the seed of an Augmented Library-style browser.
        WindowGroup(id: "KSList", for: String.self) { $raw in
            if let raw, let kind = KSWidget.ListKind(rawValue: raw) {
                KSListingView(kind: kind)
                    .environment(mapState)
            }
        }
        .defaultSize(width: 420, height: 720)

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

        // Writing a note in space: opened by the left-arm menu's New Note
        // or a card's Edit, it writes the note into the community folder.
        Window("Note", id: "MapNoteEditor") {
            MapNoteEditorView()
                .environment(mapState)
        }
        .windowResizability(.contentSize)
        .defaultWindowPlacement { _, _ in
            WindowPlacement(.utilityPanel)
        }

        // Prototype: extend a flat portrait into a 3D spatial scene.
        Window("Portrait 3D", id: "PortraitPrototype") {
            PortraitSpatialView()
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

        // The Sphere Weave: the library in the round, for the room —
        // an immersive space with the reader near its center, opened
        // from the Library window or the control bar. It takes the
        // room from the Map; only one space can hold it at a time.
        ImmersiveSpace(id: "SphereWeaveSpace") {
            SphereWeaveSpaceView()
                .environment(mapState)
        }

        // The weave's control bar: keyword, centered element, way out.
        Window("Sphere Weave", id: "SphereWeaveControls") {
            SphereWeaveControlsView()
                .environment(mapState)
        }
        .windowResizability(.contentSize)
        .defaultWindowPlacement { _, _ in
            WindowPlacement(.utilityPanel)
        }
        #else
        // A single, titled window: macOS lists "Knowledge Space" in the
        // Window menu by itself, so a closed window can always be
        // reopened from there.
        Window("Knowledge Space", id: "library") {
            ContentView()
                .environment(state)
                // The window's words default to true black (see
                // AppGreys.text); secondary and quieter styles keep
                // their own greys.
                .foregroundStyle(AppGreys.text)
                // The theme sets the window's scheme: the light designs
                // (Gentle, Darker, High Contrast) pin it to light, so
                // every divider resolves to the same separator grey
                // whatever the system appearance; Warm and Cool bring
                // their own dark mode and follow the system. Reading
                // `state.theme` re-evaluates this when the theme changes.
                .preferredColorScheme(state.theme.enforcedScheme)
        }
        // ⌘N is a new note — the core act — displacing New Window.
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") {
                    state.newNote()
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(state.index.folderURL == nil)
                Button("New Person…") {
                    state.addingPerson = true
                }
            }
            // Old-name documents (.origamitext) come home by conversion —
            // the same JSON, renamed to .liquid.json in the library folder.
            CommandGroup(after: .newItem) {
                // A meeting's words become a transcript document: every
                // statement addressable, every speaker known to People.
                Button("Import Transcript…") {
                    state.importTranscripts()
                }
                .disabled(state.index.folderURL == nil)
                Button("Convert Old Documents…") {
                    state.importLegacyDocuments()
                }
                .disabled(state.index.folderURL == nil)
            }
        }

        Settings {
            SettingsView()
                .environment(state)
                .foregroundStyle(AppGreys.text)
                .preferredColorScheme(state.theme.enforcedScheme)
        }
        #endif
    }
}

#if os(visionOS)
/// Turns a widget's tap — a `knowledgespace://list/<kind>` URL — into an
/// open listing window. Applied to the Library window, which is the
/// scene the system delivers the widget's URL to.
private struct KSWidgetDeepLink: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onOpenURL { url in
            guard let kind = KSWidget.ListKind.from(url: url) else { return }
            openWindow(id: "KSList", value: kind.rawValue)
        }
    }
}
#endif
