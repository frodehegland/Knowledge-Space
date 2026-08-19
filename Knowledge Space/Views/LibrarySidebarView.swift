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
    /// The named sections folded away under their headings — the
    /// reader's own arrangement, remembered between launches. Views
    /// starts closed; a fresh install opens everything else.
    @State private var collapsed: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "collapsedSidebarSections") ?? ["Views"])
    #if os(macOS)
    /// The place the pointer is resting on — People answers with its
    /// reveal triangle.
    @State private var hoveredItem: SidebarItem?
    #endif

    var body: some View {
        @Bindable var state = state
        // Settings holds the sidebar's foot — below the list, not over
        // it, so the column's own background shows through and the
        // scrolling rows stop above the divider.
        VStack(spacing: 0) {
            List(selection: $state.sidebarSelection) {
                ForEach(SidebarCatalog.sections(filedFolders: state.sidebarFiledFolders,
                                                folderDisplayName: state.displayName(forFolder:),
                                                articlesLabel: state.articlesShelfLabel,
                                                layout: state.sidebarLayout),
                        id: \.title) { section in
                    // The head of the column — Timeline — stands above
                    // the named headings, unnamed.
                    Section {
                        // The unnamed head always stands; a named
                        // section's rows fold away under its triangle.
                        if section.title.isEmpty || !collapsed.contains(section.title) {
                        ForEach(state.shownPlaces(of: section.places)) { place in
                            HStack(spacing: 0) {
                                // The Important row's icon wears the same
                                // orange as the Important bullet; its
                                // word reads the same dark grey as every
                                // other row.
                                if place.item == .important {
                                    Label {
                                        Text(place.name)
                                            .foregroundStyle(sidebarTextColor(for: place.item))
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
                            // Grey icons, not the accent blue — save the
                            // Important row, which stands orange, and
                            // the Archive, which stands back in the
                            // quieter mid-grey.
                            .listItemTint(place.item == .important ? .orange
                                          : isArchivedPlace(place.item) ? AppGreys.quietText
                                          : SidebarCatalog.iconTint)
                            .tag(place.item)
                            // Clicking Timeline — even already open —
                            // returns its list to Today; the tap rides
                            // beside the List's own selection.
                            .simultaneousGesture(TapGesture().onEnded {
                                if place.item == .timelineToday {
                                    state.timelineTodayPulse += 1
                                }
                            })
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
                                    Button("New \(state.displayName(forFolder: folder))") {
                                        state.newNote(filedUnder: folder)
                                    }
                                    // A rename is an alias over the
                                    // folder's own name — display only,
                                    // so any folder but Archived may
                                    // wear one.
                                    if folder.caseInsensitiveCompare(AppState.archivedFolderName) != .orderedSame {
                                        Button("Rename Folder…") {
                                            state.renameFilingFolder(folder)
                                        }
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
                        // New left the column for ⌘N and the toolbar;
                        // New Letter rests until Digital Letters'
                        // sending arrives. newLetter() stands ready.
                        if section.title == "Views" {
                            Button {
                                editingViews = true
                            } label: {
                                Label("Edit Views…", systemImage: "slider.horizontal.3")
                                    .foregroundStyle(AppGreys.quietText)
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
                    // The app's name in the headings' own ink, its
                    // regular weight — the headline face alone carries
                    // enough emphasis unbolded.
                    .font(.headline)
                    .fontWeight(.regular)
                    .foregroundStyle(AppInks.sidebarHeading)
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
            UserDefaults.standard.set(Array(collapsed), forKey: "collapsedSidebarSections")
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .foregroundStyle(AppInks.sidebarHeading)
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
        // The Archive reads quieter — set-aside, not in play.
        if isArchivedPlace(item) { return AppGreys.quietText }
        // The icons' own dark grey, so the column's words and symbols
        // read as one set — and stay legible in the dark themes.
        return AppGreys.buttonText
    }

    /// The Archive's place, told apart so its row can stand back.
    private func isArchivedPlace(_ item: SidebarItem) -> Bool {
        if case .filedFolder(let folder) = item {
            return folder.caseInsensitiveCompare(AppState.archivedFolderName) == .orderedSame
        }
        return false
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

/// The window's appearance, chosen in Settings ▸ Appearance — Author's
/// themes, carried across colour for colour from its asset catalogue,
/// in its menu's order. Every theme has a light and a dark side and
/// follows the system appearance. The pop-up's last item — Edit Theme
/// Colors…, as Author's menu ends — sets the chosen theme's colours
/// individually, stored as overrides on that theme.
enum AppTheme: String, CaseIterable, Identifiable {
    case gentle
    case highContrast
    case lowContrast
    case warm
    case warmStrong
    case cool
    case coolStrong

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gentle: "Gentle"
        case .highContrast: "High Contrast"
        case .lowContrast: "Low Contrast"
        case .warm: "Warm"
        case .warmStrong: "Warm Strong"
        case .cool: "Cool"
        case .coolStrong: "Cool Strong"
        }
    }

    static let key = "appearanceTheme"

    static var current: AppTheme {
        let stored = UserDefaults.standard.string(forKey: key) ?? ""
        if let theme = AppTheme(rawValue: stored) { return theme }
        // Names from the earlier design: Darker reads as Low Contrast,
        // its nearest kin; anything else as Author's default, Warm.
        if stored == "darker" { return .lowContrast }
        return .warm
    }
}

/// One theme colour as its components — kept numeric so the values can
/// be written down and compared against Author's assets exactly.
struct ThemeRGB: Equatable {
    let red: Double
    let green: Double
    let blue: Double

    init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    var color: Color { Color(red: red, green: green, blue: blue) }

    /// Mixed toward another colour — the quiet derivations (the
    /// buttons) Author's catalogue has no colour of its own for.
    func mixed(with other: ThemeRGB, by fraction: Double) -> ThemeRGB {
        ThemeRGB(red + (other.red - red) * fraction,
                 green + (other.green - green) * fraction,
                 blue + (other.blue - blue) * fraction)
    }

    /// The persisted form of an override: "r g b", components 0–1.
    var stored: String { "\(red) \(green) \(blue)" }

    init?(stored: String) {
        let parts = stored.split(separator: " ").compactMap(Double.init)
        guard parts.count == 3 else { return nil }
        self.init(parts[0], parts[1], parts[2])
    }
}

/// The four colours a theme paints: the page behind the words, the
/// body ink, the heading ink, and the dimmed ink for quiet text.
enum ThemeRole: String, CaseIterable, Identifiable {
    case background
    case text
    case heading
    case dimmed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .background: "Background"
        case .text: "Body text"
        case .heading: "Heading text"
        case .dimmed: "Dimmed text"
        }
    }
}

extension AppTheme {
    /// Author's colour for a role — light or dark side, the values read
    /// from its asset catalogue. Gentle borrows its dimmed ink from
    /// High Contrast, as Author does.
    func builtIn(_ role: ThemeRole, dark: Bool) -> ThemeRGB {
        switch (self, role) {
        case (.gentle, .background):
            dark ? ThemeRGB(0.2078, 0.2078, 0.2039) : ThemeRGB(1, 1, 1)
        case (.gentle, .text):
            dark ? ThemeRGB(0.6824, 0.6824, 0.6824) : ThemeRGB(0.4, 0.4, 0.4)
        case (.gentle, .heading):
            dark ? ThemeRGB(0.851, 0.8588, 0.8392) : ThemeRGB(0.8431, 0.8431, 0.8431)
        case (.gentle, .dimmed), (.highContrast, .dimmed):
            dark ? ThemeRGB(0.3059, 0.3059, 0.3176) : ThemeRGB(0.8118, 0.8078, 0.8078)
        case (.highContrast, .background):
            dark ? ThemeRGB(0, 0, 0) : ThemeRGB(1, 1, 1)
        case (.highContrast, .text):
            dark ? ThemeRGB(1, 1, 1) : ThemeRGB(0, 0, 0)
        case (.highContrast, .heading):
            dark ? ThemeRGB(0.6863, 0.6824, 0.6824) : ThemeRGB(0.4471, 0.451, 0.4471)
        case (.lowContrast, .background):
            dark ? ThemeRGB(0.1333, 0.1333, 0.1294) : ThemeRGB(0.8627, 0.8667, 0.8627)
        case (.lowContrast, .text):
            dark ? ThemeRGB(0.4824, 0.4784, 0.4745) : ThemeRGB(0.3451, 0.349, 0.3451)
        case (.lowContrast, .heading):
            dark ? ThemeRGB(0.6863, 0.6824, 0.6824) : ThemeRGB(0.4118, 0.4157, 0.4157)
        case (.lowContrast, .dimmed):
            dark ? ThemeRGB(0.4627, 0.4667, 0.4706) : ThemeRGB(0.7098, 0.7137, 0.7137)
        case (.warm, .background):
            dark ? ThemeRGB(0.2392, 0.2118, 0.2) : ThemeRGB(0.9608, 0.9255, 0.8627)
        case (.warm, .text):
            dark ? ThemeRGB(0.9765, 0.9765, 0.9725) : ThemeRGB(0.2863, 0.2784, 0.2588)
        case (.warm, .heading):
            dark ? ThemeRGB(0.6941, 0.6824, 0.6784) : ThemeRGB(0, 0, 0)
        case (.warm, .dimmed):
            dark ? ThemeRGB(0.3059, 0.2824, 0.2667) : ThemeRGB(0.6863, 0.6667, 0.6196)
        case (.warmStrong, .background):
            dark ? ThemeRGB(0.149, 0.1255, 0.1176) : ThemeRGB(0.7647, 0.6784, 0.6078)
        case (.warmStrong, .text):
            dark ? ThemeRGB(1, 1, 1) : ThemeRGB(0.149, 0.1373, 0.1216)
        case (.warmStrong, .heading):
            dark ? ThemeRGB(0.6627, 0.6549, 0.6471) : ThemeRGB(0.1529, 0.1373, 0.1216)
        case (.warmStrong, .dimmed):
            dark ? ThemeRGB(0.3725, 0.3451, 0.3216) : ThemeRGB(0.6588, 0.6314, 0.5255)
        case (.cool, .background):
            dark ? ThemeRGB(0.1686, 0.2431, 0.3098) : ThemeRGB(0.8471, 0.8824, 0.9176)
        case (.cool, .text):
            dark ? ThemeRGB(0.6941, 0.7333, 0.7529) : ThemeRGB(0.3412, 0.3529, 0.3647)
        case (.cool, .heading):
            dark ? ThemeRGB(0.6941, 0.7333, 0.7529) : ThemeRGB(0.2588, 0.3608, 0.4353)
        case (.cool, .dimmed):
            dark ? ThemeRGB(0.2235, 0.2588, 0.2784) : ThemeRGB(0.6431, 0.6745, 0.7137)
        case (.coolStrong, .background):
            dark ? ThemeRGB(0.1725, 0.2196, 0.251) : ThemeRGB(0.7176, 0.7686, 0.8118)
        case (.coolStrong, .text):
            dark ? ThemeRGB(0.6941, 0.7255, 0.7451) : ThemeRGB(0.2157, 0.3255, 0.4196)
        case (.coolStrong, .heading):
            dark ? ThemeRGB(0.7647, 0.7882, 0.7961) : ThemeRGB(0.2157, 0.3255, 0.4196)
        case (.coolStrong, .dimmed):
            dark ? ThemeRGB(0.4549, 0.4941, 0.5216) : ThemeRGB(0.5216, 0.5608, 0.6)
        }
    }

    /// The UserDefaults key one override lives under.
    private func overrideKey(_ role: ThemeRole, dark: Bool) -> String {
        "themeColor.\(rawValue).\(role.rawValue).\(dark ? "dark" : "light")"
    }

    /// The user's colour for a role, when Edit Theme Colors… set one.
    func override(_ role: ThemeRole, dark: Bool) -> ThemeRGB? {
        UserDefaults.standard.string(forKey: overrideKey(role, dark: dark))
            .flatMap(ThemeRGB.init(stored:))
    }

    /// Nil removes the override — Reset, restoring the built-in colour.
    func setOverride(_ rgb: ThemeRGB?, for role: ThemeRole, dark: Bool) {
        let key = overrideKey(role, dark: dark)
        if let rgb {
            UserDefaults.standard.set(rgb.stored, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// The colour in force: the user's override when one is set,
    /// Author's built-in otherwise.
    func effective(_ role: ThemeRole, dark: Bool) -> ThemeRGB {
        override(role, dark: dark) ?? builtIn(role, dark: dark)
    }

    /// The role as an adaptive colour, following the system appearance.
    func color(_ role: ThemeRole) -> Color {
        .adaptive(light: effective(role, dark: false).color,
                  dark: effective(role, dark: true).color)
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

/// The window's colors, answering for the chosen theme — Author's
/// palette painting the columns, the list, and the writing page
/// together, every shade following the system's light and dark
/// appearance.
/// The inks beyond the themes: the deep burgundy (#711A20) the
/// sidebar's section headings wear — Frode's choice, 16 Aug 2026.
enum AppInks {
    static let sidebarHeading = Color(red: 0x71 / 255.0,
                                      green: 0x1A / 255.0,
                                      blue: 0x20 / 255.0)
}

enum AppGreys {
    static var column: Color { AppTheme.current.color(.background) }
    static var page: Color { AppTheme.current.color(.background) }
    /// The default for every word in the window: the theme's body ink.
    static var text: Color { AppTheme.current.color(.text) }
    /// The theme's heading ink — the reading page's headings.
    static var heading: Color { AppTheme.current.color(.heading) }
    /// The dimmed ink for the sidebar's secondary rows — Edit Views…
    /// and Archived — the theme's own quiet shade.
    static var quietText: Color { AppTheme.current.color(.dimmed) }
    /// Author's catalogue has no button colour: a quiet mix of the
    /// theme's page toward its ink, in both appearances.
    static var button: Color {
        let theme = AppTheme.current
        return .adaptive(
            light: theme.effective(.background, dark: false)
                .mixed(with: theme.effective(.text, dark: false), by: 0.12).color,
            dark: theme.effective(.background, dark: true)
                .mixed(with: theme.effective(.text, dark: true), by: 0.12).color)
    }
    static var buttonText: Color { AppTheme.current.color(.text) }
    static var buttonBorder: Color {
        AppTheme.current == .highContrast ? text : .clear
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
