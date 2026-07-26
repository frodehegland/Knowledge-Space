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
    /// The person form, opened from ctrl-click on People.
    @State private var addingPerson = false
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
                            Label(place.name, systemImage: place.systemImage)
                                // Light grey icons, not the accent blue.
                                .listItemTint(SidebarCatalog.iconTint)
                                .tag(place.item)
                                #if os(macOS)
                                // Ctrl-click on People adds someone to the
                                // shared contact directory.
                                .contextMenu {
                                    if place.item == .people {
                                        Button("New Person…") {
                                            addingPerson = true
                                        }
                                    }
                                }
                                #endif
                        }
                        if section.title.isEmpty {
                            Button {
                                state.newNote()
                            } label: {
                                Label {
                                    Text("New Note")
                                        .foregroundStyle(.secondary)
                                } icon: {
                                    Image(systemName: "square.and.pencil")
                                        .foregroundStyle(SidebarCatalog.iconTint)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(state.index.folderURL == nil)
                            .help("A new note, straight into writing (⌘N)")
                        }
                        if section.title == "Views" {
                            Button {
                                editingViews = true
                            } label: {
                                Label("Edit Views…", systemImage: "slider.horizontal.3")
                                    .foregroundStyle(.secondary)
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
        // The same column width as Liquid Information's sidebar.
        .navigationSplitViewColumnWidth(min: 215, ideal: 230)
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

/// The grey the window's side columns share — the sidebar and the note
/// options column. One flat shade, darker than the stock sidebar, with
/// the dark scheme forced so every label on it stands in white.
extension View {
    func greyColumnAppearance() -> some View {
        self
            .background(Color(white: 0.18).ignoresSafeArea())
            .environment(\.colorScheme, .dark)
    }
}
