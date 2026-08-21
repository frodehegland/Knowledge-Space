import SwiftUI
import UniformTypeIdentifiers

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
/// Catches files handed to the app itself — an email or an EPUB
/// dropped on the Dock icon, or opened with Knowledge Space from the
/// Finder — and turns each into a document. ContentView points
/// `state` here on appearance.
final class MailOpenDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var state: AppState?

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            Self.state?.openFiles(urls)
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
    /// The colour-coded reading, switched from the View menu — the
    /// same stored choice the reader's Aa menu and Settings ▸
    /// Colouring speak to.
    @AppStorage("textColoringMode") private var coloringModeRaw =
        TextColoringMode.off.rawValue
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
                // Every theme has a light and a dark side and follows
                // the system appearance. Reading the stamp re-paints
                // the window when the theme — or one of its colours,
                // in Edit Theme Colors… — changes.
                .id(state.themeStamp)
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
                // The Open dialog: the kinds the app adopts — EPUBs
                // (read whole into the library) and emails — through
                // the same door the Finder and the Dock icon use.
                Button("Open…") {
                    openFiles()
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(state.index.folderURL == nil)
                Divider()
                // A meeting's words become a transcript document: every
                // statement addressable, every speaker known to People.
                Button("Import Transcript…") {
                    state.importTranscripts()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(state.index.folderURL == nil)
                Button("Convert Old Documents…") {
                    state.importLegacyDocuments()
                }
                .disabled(state.index.folderURL == nil)
                Divider()
                // The world's PDFs as citable EPUBs, and Author's own
                // EPUBs with their citation pools — one door for both.
                // See SourceCitations.swift.
                Button("PDF-EPUB…") {
                    state.importPDFEPUB()
                }
                .disabled(state.index.folderURL == nil)
            }
            // The View menu carries the ways of seeing the notes —
            // the same toggles the note's options column offers, here
            // with the menu's checkmarks and shortcuts.
            CommandGroup(after: .toolbar) {
                Divider()
                Toggle("Flow", isOn: Binding(
                    get: { state.flowReading },
                    set: { state.flowReading = $0 }))
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                // Colour coding, as the reader's Aa menu offers it —
                // Grammar paints by part of speech, Meaning by the
                // people, places, and organizations named.
                Picker("Colour Words By", selection: $coloringModeRaw) {
                    ForEach(TextColoringMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                Toggle("Show Superseded", isOn: Binding(
                    get: { state.showsSuperseded },
                    set: { state.showsSuperseded = $0 }))
                Divider()
            }
            // ⌘＋/⌘－ answer to what is front: over a reading whose
            // document has headings they unfold and fold its outline —
            // as in Author — and otherwise they size the notes list's
            // text, as they always have.
            TextSizeOrOutlineCommands(state: state)
            // The foot of the File menu: the front book as a folded,
            // saddle-stitched booklet, standing disabled while nothing
            // front can print. The shelves offer the same by right-click.
            BookletPrintCommands(state: state)
        }

        // A work in a window of its own: double-clicking a book on the
        // EPUB shelf, or opening an EPUB from the Finder, reads here —
        // as many windows as there are books open.
        WindowGroup("Reading", id: "reading", for: String.self) { $docID in
            ReadingWindowView(docID: docID)
                .environment(state)
                .foregroundStyle(AppGreys.text)
                .id(state.themeStamp)
        }
        .defaultSize(width: 760, height: 900)

        // The camera watching for a printed page — File ▸ Hold Up a
        // Page… — one window, reused.
        Window("Hold Up a Page", id: "pageCamera") {
            PageCaptureView()
                .environment(state)
                .foregroundStyle(AppGreys.text)
        }
        .defaultSize(width: 560, height: 440)

        Settings {
            SettingsView()
                .environment(state)
                .foregroundStyle(AppGreys.text)
                // The theme alone, not its colour edits: a repaint
                // mid-edit would close the editor's sheet.
                .id(state.theme)
        }
        #endif
    }

    #if os(macOS)
    /// File ▸ Open… — the kinds the app adopts, several at once.
    private func openFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [
            UTType.epub,
            UTType("com.apple.mail.email"),
            UTType("public.email-message"),
        ].compactMap { $0 }
        panel.message = "Open EPUBs and emails into the library — an Origami EPUB arrives whole, text, glossary, and images."
        guard panel.runModal() == .OK else { return }
        state.openFiles(panel.urls)
    }
    #endif
}

#if os(macOS)
/// One document read in its own window, found in the index by id —
/// the whole reader: citations resolved, images, tables, daggers.
private struct ReadingWindowView: View {
    @Environment(AppState.self) private var state
    let docID: String?

    var body: some View {
        if let docID, let doc = state.index.allByID[docID]?.doc {
            // The book reader: Author's and Augmented Library's view
            // styles — article, outline, focus, transcript — with the
            // reading menu, glossary, folding, and annotations.
            OrigamiReadingView(doc: doc)
                .id(doc.id)
        } else {
            Text("The document is not in the library yet — it appears here once its import lands.")
                .foregroundStyle(.secondary)
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppGreys.page)
        }
    }
}
#endif

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

/// The View menu's folding and sizing: ⌘－/⌘＋ fold the front reading
/// into its outline and open it whole — as in Author — standing
/// disabled while no reading with headings is front. Text sizing
/// lives at ⌘⇧－/⌘⇧＋. The reader publishes its fold actions through
/// the focused scene (see DocumentReaderView).
private struct TextSizeOrOutlineCommands: Commands {
    let state: AppState
    @FocusedValue(\.outlineFold) private var outlineFold
    @FocusedValue(\.readingTypography) private var readingType

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Fold Into Outline") {
                outlineFold?.fold()
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(outlineFold == nil)
            Button("Unfold Outline") {
                outlineFold?.unfold()
            }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(outlineFold == nil)
            Divider()
            // ⌘⇧± size whatever text is front: the book reader's page
            // when a reading is front, the notes list otherwise.
            Button("Make Text Bigger") {
                if let readingType {
                    readingType.bigger()
                } else {
                    state.listTextSize = min(state.listTextSize + 1, 36)
                }
            }
            .keyboardShortcut("+", modifiers: [.command, .shift])
            Button("Make Text Smaller") {
                if let readingType {
                    readingType.smaller()
                } else {
                    state.listTextSize = max(state.listTextSize - 1, 9)
                }
            }
            .keyboardShortcut("-", modifiers: [.command, .shift])
            Button("Looser Lines") {
                readingType?.looser()
            }
            .keyboardShortcut("+", modifiers: [.command, .option])
            .disabled(readingType == nil)
            Button("Tighter Lines") {
                readingType?.tighter()
            }
            .keyboardShortcut("-", modifiers: [.command, .option])
            .disabled(readingType == nil)
        }
    }
}

#if os(macOS)
/// The File menu's foot — where paper meets the app. Print Booklet…
/// runs Author's imposition over whatever book is front: the reading
/// publishes its .epub through the focused scene (see
/// OrigamiReadingView), and the item stands disabled while no book is
/// front. Hold Up a Page… goes the other way: the camera reads a
/// printed page and opens its document at that place.
private struct BookletPrintCommands: Commands {
    let state: AppState
    @FocusedValue(\.bookletSource) private var bookletSource
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .printItem) {
            Button("Print Booklet\u{2026}") {
                if let bookletSource { state.printBooklet(from: bookletSource) }
            }
            .disabled(bookletSource == nil)
            Button("Hold Up a Page\u{2026}") {
                openWindow(id: "pageCamera")
            }
        }
    }
}
#endif
