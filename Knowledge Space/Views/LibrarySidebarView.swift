import SwiftUI

/// The window's first column: the document library, then every installed
/// view module. The Views list is the user's to curate — Edit Views…
/// shows and hides modules without uninstalling them.
struct LibrarySidebarView: View {
    @Environment(AppState.self) private var state
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif
    @State private var editingViews = false
    /// The named sections folded away under their headings — Views
    /// starts closed.
    @State private var collapsed: Set<String> = ["Views"]
    #if os(macOS)
    /// The place the pointer is resting on — People answers with its
    /// reveal triangle.
    @State private var hoveredItem: SidebarItem?
    @State private var isNewHovered = false
    #endif

    var body: some View {
        @Bindable var state = state
        // Settings holds the sidebar's foot — below the list, not over
        // it, so the column's own background shows through and the
        // scrolling rows stop above the divider.
        VStack(spacing: 0) {
            List(selection: $state.sidebarSelection) {
                ForEach(SidebarCatalog.sections(filedFolders: state.sidebarFiledFolders,
                                                articlesLabel: state.articlesShelfLabel,
                                                importantToDo: state.hasImportantToDo,
                                                layout: state.sidebarLayout),
                        id: \.title) { section in
                    // The head of the column — Inbox and New Note —
                    // stands above the Library heading, unnamed.
                    Section {
                        // The unnamed head always stands; a named
                        // section's rows fold away under its triangle.
                        if section.title.isEmpty || !collapsed.contains(section.title) {
                        ForEach(state.shownPlaces(of: section.places)) { place in
                            HStack(spacing: 0) {
                                // The important-To-Do row wears the same
                                // orange as the Important bullet, word and
                                // icon alike; every other row is grey.
                                if place.item == .importantToDo {
                                    Label {
                                        Text(place.name).foregroundStyle(.orange)
                                    } icon: {
                                        Image(systemName: place.systemImage)
                                            .foregroundStyle(.orange)
                                    }
                                } else {
                                    Label {
                                        Text(place.name)
                                            .foregroundStyle(sidebarTextColor(for: place.item))
                                    } icon: {
                                        Image(systemName: place.systemImage)
                                    }
                                }
                                Spacer(minLength: 0)
                                #if os(macOS)
                                // Resting the pointer on People reveals a
                                // triangle; it opens the way to a new
                                // person in the shared contact directory.
                                if place.item == .people, hoveredItem == .people {
                                    Menu {
                                        Button("New Person…") {
                                            state.addingPerson = true
                                        }
                                    } label: {
                                        Image(systemName: "chevron.down")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                    .menuIndicator(.hidden)
                                    .buttonStyle(.plain)
                                    .fixedSize()
                                    .help("Add a person to the contacts")
                                }
                                #endif
                            }
                            // Light grey icons, not the accent blue — save
                            // the important-To-Do row, which stands orange.
                            .listItemTint(place.item == .importantToDo ? .orange : SidebarCatalog.iconTint)
                            .tag(place.item)
                            #if os(macOS)
                            .contextMenu {
                                // A standing's place starts a note with
                                // that standing — New To Do, New Question.
                                if case .action(let action) = place.item {
                                    Button("New \(action.displayName)") {
                                        state.newNote(action: action)
                                    }
                                }
                                // A filed folder's place starts a note
                                // filed there — New Journal, and so on —
                                // and offers to remove a folder of the
                                // user's own making; its notes stay.
                                if case .filedFolder(let folder) = place.item {
                                    Button("New \(folder)") {
                                        state.newNote(filedUnder: folder)
                                    }
                                    // The Archive can be emptied whole:
                                    // every note filed there to the Trash.
                                    if folder.caseInsensitiveCompare(AppState.archivedFolderName) == .orderedSame,
                                       state.archivedCount > 0 {
                                        Divider()
                                        Button("Delete All Archived…", role: .destructive) {
                                            state.deleteAllArchived()
                                        }
                                    }
                                    if state.canRemoveFilingFolder(folder) {
                                        Divider()
                                        Button("Remove Folder…", role: .destructive) {
                                            state.removeFilingFolder(folder)
                                        }
                                    }
                                }
                            }
                            #endif
                            #if os(macOS)
                            .onHover { inside in
                                hoveredItem = inside ? place.item : nil
                            }
                            #endif
                        }
                        if section.title.isEmpty {
                            Button {
                                state.newNote()
                            } label: {
                                Label {
                                    Text("New")
                                        .foregroundStyle(isNewHovered ? Color.primary : Color(white: 169 / 255))
                                } icon: {
                                    Image(systemName: "square.and.pencil")
                                        .foregroundStyle(isNewHovered ? Color.primary : Color(white: 169 / 255))
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(state.index.folderURL == nil)
                            .help("A new note, straight into writing (⌘N)")
                            #if os(macOS)
                            .onHover { isNewHovered = $0 }
                            #endif
                            // New Letter is resting for now; the act
                            // returns when Digital Letters' sending
                            // arrives. newLetter() stands ready.
                        }
                        if section.title == "Views" {
                            Button {
                                editingViews = true
                            } label: {
                                Label("Edit Views…", systemImage: "slider.horizontal.3")
                                    .foregroundStyle(AppGreys.buttonText)
                            }
                            .buttonStyle(.plain)
                        }
                        }
                    } header: {
                        if !section.title.isEmpty {
                            sectionHeader(section.title)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            // The app's name stands over the list, above Library.
            .safeAreaInset(edge: .top, spacing: 0) {
                Text("Knowledge Space")
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundStyle(Color(white: 169 / 255))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 18)
            }
            .scrollContentBackground(.hidden)

            #if os(macOS)
            Divider()
            Button {
                openSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .foregroundStyle(AppGreys.buttonText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            #endif
        }
        // The columns' shared grey stands in for the stock sidebar
        // material, so Knowledge Space is told apart from Liquid
        // Information at a glance.
        .greyColumnAppearance()
        // The same thin line the options column stands behind: the flat
        // greys swallow the split view's own divider, so the sidebar
        // draws its edge itself.
        .overlay(alignment: .trailing) {
            HStack(spacing: 0) { Divider() }
                .ignoresSafeArea()
        }
        .sheet(isPresented: $editingViews) {
            EditViewsSheet()
        }
        .navigationTitle("Knowledge Space")
        // A slim spine, but never slimmer than 230 points — room for
        // the app's own name, "Knowledge Space", to stand whole, and
        // the longest section entries with it.
        .navigationSplitViewColumnWidth(min: 280, ideal: 295)
    }

    /// A section heading that folds its rows away: the title with a
    /// reveal triangle to its right, turned down when the section is
    /// open, resting on its side when it is closed.
    private func sectionHeader(_ title: String) -> some View {
        Button {
            withAnimation(.snappy) {
                if collapsed.contains(title) {
                    collapsed.remove(title)
                } else {
                    collapsed.insert(title)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .foregroundStyle(Color(white: 169 / 255))
                // A small triangle just past the title, not out at the
                // column's edge: turned down when open, on its side
                // when closed.
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(collapsed.contains(title) ? 0 : 90))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sidebarTextColor(for item: SidebarItem) -> Color {
        if state.sidebarSelection == item || hoveredItem == item {
            return .primary
        }
        return Color(white: 169 / 255)
    }
}

/// Edit Views: every installed view with a check for whether it shows
/// on the sidebar, and how the list grows — importing a view someone
/// shared, or writing one.
struct EditViewsSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Views on the Sidebar") {
                    ForEach(LibraryViewRegistry.modules) { module in
                        Toggle(isOn: shown(module.id)) {
                            Label(module.name, systemImage: module.systemImage)
                        }
                        #if os(macOS)
                        .toggleStyle(.checkbox)
                        #endif
                    }
                }
                Section("Importing a View") {
                    Text("A view travels as a single Swift file or a .origamiview archive. An archive whose code this build already contains starts working at once; a brand-new one is held, its source ready, until the app is next built with it.")
                        .font(.callout)
                }
                Section("Making a View") {
                    Text("A view is one Swift file: a SwiftUI view over the library, plus a small LibraryViewModule declaration and one registry line — LibraryViewModule.swift holds the recipe.")
                        .font(.callout)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 480, height: 560)
    }

    /// Checked means on the sidebar.
    private func shown(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !state.isViewHidden(id) },
            set: { state.setView(id, hidden: !$0) }
        )
    }
}

/// The window's appearance, chosen in Settings ▸ Appearance. Gentle,
/// Darker, and High Contrast are fixed light designs. Warm and Cool are
/// tinted and bring their own dark mode: they follow the system between
/// a light and a dark shade.
enum AppTheme: String, CaseIterable, Identifiable {
    case gentle
    case darker
    case warm
    case cool
    case highContrast

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gentle: "Gentle"
        case .darker: "Darker"
        case .warm: "Warm"
        case .cool: "Cool"
        case .highContrast: "High Contrast"
        }
    }

    /// The scheme the theme pins the window to. Warm and Cool return nil
    /// — they follow the system, dark or light; the rest hold the fixed
    /// light design.
    var enforcedScheme: ColorScheme? {
        switch self {
        case .warm, .cool: nil
        default: .light
        }
    }

    static let key = "appearanceTheme"

    static var current: AppTheme {
        AppTheme(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .cool
    }
}

/// A color that resolves to `light` or `dark` per the environment's
/// color scheme — the adaptive themes' way of bringing dark mode.
extension Color {
    static func adaptive(light: Color, dark: Color) -> Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(dark) : NSColor(light)
        })
        #else
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #endif
    }
}

/// The window's colors, answering for the chosen theme. Gentle: side
/// columns #eaeaea, buttons #d9d9d9 with #4d4d4d text, the list and
/// writing page #ebebeb, every other word black. High Contrast:
/// everything white, all text black. Warm and Cool are tinted and
/// adapt to the system's light or dark appearance.
enum AppGreys {
    // Warm: #dcd7ce in light, #2d2a26 in dark.
    private static let warmPage = Color.adaptive(
        light: Color(red: 220 / 255, green: 215 / 255, blue: 206 / 255),
        dark: Color(red: 45 / 255, green: 42 / 255, blue: 38 / 255))
    private static let warmButton = Color.adaptive(
        light: Color(red: 207 / 255, green: 201 / 255, blue: 189 / 255),
        dark: Color(red: 60 / 255, green: 56 / 255, blue: 51 / 255))
    private static let warmButtonText = Color.adaptive(
        light: Color(red: 74 / 255, green: 70 / 255, blue: 63 / 255),
        dark: Color(red: 216 / 255, green: 211 / 255, blue: 201 / 255))
    // Cool: #cfd5dd in light, #232831 in dark.
    private static let coolPage = Color.adaptive(
        light: Color(red: 207 / 255, green: 213 / 255, blue: 221 / 255),
        dark: Color(red: 35 / 255, green: 40 / 255, blue: 49 / 255))
    private static let coolButton = Color.adaptive(
        light: Color(red: 186 / 255, green: 192 / 255, blue: 200 / 255),
        dark: Color(red: 49 / 255, green: 55 / 255, blue: 66 / 255))
    private static let coolButtonText = Color.adaptive(
        light: Color(red: 64 / 255, green: 69 / 255, blue: 76 / 255),
        dark: Color(red: 205 / 255, green: 210 / 255, blue: 217 / 255))

    static var column: Color {
        switch AppTheme.current {
        case .highContrast: .white
        case .darker: Color(white: 209 / 255)
        case .warm: warmPage
        case .cool: coolPage
        case .gentle: Color(red: 234 / 255, green: 234 / 255, blue: 234 / 255)
        }
    }
    static var button: Color {
        switch AppTheme.current {
        case .highContrast: .white
        case .darker: Color(white: 194 / 255)
        case .warm: warmButton
        case .cool: coolButton
        case .gentle: Color(red: 217 / 255, green: 217 / 255, blue: 217 / 255)
        }
    }
    static var buttonText: Color {
        switch AppTheme.current {
        case .highContrast: .black
        case .darker: Color(white: 58 / 255)
        case .warm: warmButtonText
        case .cool: coolButtonText
        case .gentle: Color(red: 77 / 255, green: 77 / 255, blue: 77 / 255)
        }
    }
    static var buttonBorder: Color {
        AppTheme.current == .highContrast ? .black : .clear
    }
    static var page: Color {
        switch AppTheme.current {
        case .highContrast: .white
        case .darker: Color(white: 212 / 255)
        case .warm: warmPage
        case .cool: coolPage
        case .gentle: Color(red: 235 / 255, green: 235 / 255, blue: 235 / 255)
        }
    }
    /// The default for every other word in the window. Fixed black for
    /// the light designs; black-or-white for Warm and Cool, so words
    /// stay readable when they turn dark.
    static var text: Color {
        switch AppTheme.current {
        case .warm, .cool: .adaptive(light: .black, dark: .white)
        default: .black
        }
    }
}

/// The tint the window's side columns share — the sidebar and the note
/// options column. The colors already answer to the theme (and, for
/// Warm and Cool, to the system's dark mode); the column simply wears
/// its theme's column shade.
extension View {
    func greyColumnAppearance() -> some View {
        self
            .background(AppGreys.column.ignoresSafeArea())
    }
}

/// The side columns' button: a quiet rounded rectangle, #616161 words
/// on #e0e0e0.
struct GreyColumnButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(AppGreys.buttonText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppGreys.button, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(AppGreys.buttonBorder))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
