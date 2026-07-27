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
    #if os(macOS)
    /// The person form, revealed from the People row.
    @State private var addingPerson = false
    /// The place the pointer is resting on — People answers with its
    /// reveal triangle.
    @State private var hoveredPlace: SidebarItem?
    #endif

    var body: some View {
        @Bindable var state = state
        // Settings holds the sidebar's foot — below the list, not over
        // it, so the column's own background shows through and the
        // scrolling rows stop above the divider.
        VStack(spacing: 0) {
            List(selection: $state.sidebarSelection) {
                ForEach(SidebarCatalog.sections(filedFolders: state.sidebarFiledFolders),
                        id: \.title) { section in
                    // The head of the column — Inbox and New Note —
                    // stands above the Library heading, unnamed.
                    Section {
                        ForEach(state.shownPlaces(of: section.places)) { place in
                            HStack(spacing: 0) {
                                Label(place.name, systemImage: place.systemImage)
                                Spacer(minLength: 0)
                                #if os(macOS)
                                // Resting the pointer on People reveals a
                                // triangle; it opens the way to a new
                                // person in the shared contact directory.
                                if place.item == .people, hoveredPlace == .people {
                                    Menu {
                                        Button("New Person…") {
                                            addingPerson = true
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
                            // Light grey icons, not the accent blue.
                            .listItemTint(SidebarCatalog.iconTint)
                            .tag(place.item)
                            #if os(macOS)
                            // Ctrl-click a filing folder of the user's own
                            // making to remove the category; its notes stay.
                            .contextMenu {
                                if case .filedFolder(let folder) = place.item,
                                   state.canRemoveFilingFolder(folder) {
                                    Button("Remove Folder…", role: .destructive) {
                                        state.removeFilingFolder(folder)
                                    }
                                }
                            }
                            #endif
                            #if os(macOS)
                            .onHover { inside in
                                guard place.item == .people else { return }
                                hoveredPlace = inside ? .people : nil
                            }
                            #endif
                        }
                        if section.title.isEmpty {
                            Button {
                                state.newNote()
                            } label: {
                                Label {
                                    Text("New Note")
                                        .foregroundStyle(AppGreys.buttonText)
                                } icon: {
                                    Image(systemName: "square.and.pencil")
                                        .foregroundStyle(SidebarCatalog.iconTint)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(state.index.folderURL == nil)
                            .help("A new note, straight into writing (⌘N)")
                            Button {
                                state.newLetter()
                            } label: {
                                Label {
                                    Text("New Letter")
                                        .foregroundStyle(AppGreys.buttonText)
                                } icon: {
                                    Image(systemName: "envelope")
                                        .foregroundStyle(SidebarCatalog.iconTint)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(state.index.folderURL == nil)
                            .help("A new letter — a note marked Letter, drafted under Draft Letters")
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
                    } header: {
                        if !section.title.isEmpty {
                            Text(section.title)
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
                    .foregroundStyle(.primary)
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
        #if os(macOS)
        .sheet(isPresented: $addingPerson) {
            PersonFormView(person: Person(), heading: "New Person") { person in
                state.people.upsert(person)
                state.publishPortraits()
                state.index.rescan()
            }
        }
        #endif
        .navigationTitle("Knowledge Space")
        // A slim spine, but never so slim the app's own name truncates:
        // the minimum holds "Knowledge Space" whole at its headline size.
        .navigationSplitViewColumnWidth(min: 160, ideal: 170)
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

/// The window's appearance, chosen in Settings ▸ Appearance: Gentle is
/// the design's quiet greys; High Contrast is black text on white.
enum AppTheme: String, CaseIterable, Identifiable {
    case gentle
    case highContrast

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gentle: "Gentle"
        case .highContrast: "High Contrast"
        }
    }

    static let key = "appearanceTheme"

    static var current: AppTheme {
        AppTheme(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .gentle
    }
}

/// The window's colors, answering for the chosen theme. Gentle: side
/// columns #eaeaea, buttons #d9d9d9 with #4d4d4d text, the list and
/// writing page #ebebeb, every other word black. High Contrast:
/// everything white, all text black, buttons outlined so they still
/// read as buttons.
enum AppGreys {
    static var column: Color {
        AppTheme.current == .highContrast
            ? .white : Color(red: 234 / 255, green: 234 / 255, blue: 234 / 255)
    }
    static var button: Color {
        AppTheme.current == .highContrast
            ? .white : Color(red: 217 / 255, green: 217 / 255, blue: 217 / 255)
    }
    static var buttonText: Color {
        AppTheme.current == .highContrast
            ? .black : Color(red: 77 / 255, green: 77 / 255, blue: 77 / 255)
    }
    static var buttonBorder: Color {
        AppTheme.current == .highContrast ? .black : .clear
    }
    static var page: Color {
        AppTheme.current == .highContrast
            ? .white : Color(red: 235 / 255, green: 235 / 255, blue: 235 / 255)
    }
    /// The default for every other word in the window — body, lists,
    /// sidebar: pure black, not the system's softened label grey.
    /// Applied once at the window root; .secondary and explicit greys
    /// still read as themselves.
    static var text: Color { .black }
}

/// The grey the window's side columns share — the sidebar and the note
/// options column. One flat light shade, the light scheme held so the
/// greys read the same whatever the system appearance.
extension View {
    func greyColumnAppearance() -> some View {
        self
            .background(AppGreys.column.ignoresSafeArea())
            .environment(\.colorScheme, .light)
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
