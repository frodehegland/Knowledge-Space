#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImagePlayground
import FoundationModels

/// The app's Settings window (Knowledge Space → Settings…, ⌘,) — the
/// panes carried over from Origami Text that apply here: who is reading,
/// where the library is, the AI views' prompts, the view-module
/// exchange, and the open-source doorway. The editor, dialog, and
/// portrait panes stayed with Origami Text along with the features they
/// govern.
struct SettingsView: View {
    var body: some View {
        TabView {
            AuthorSettingsView()
                .tabItem { Label("Author", systemImage: "person.text.rectangle") }
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            LibrarySettingsView()
                .tabItem { Label("Library", systemImage: "books.vertical") }
            LocationsSettingsView()
                .tabItem { Label("Locations", systemImage: "mappin.and.ellipse") }
            AISettingsView()
                .tabItem { Label("AI", systemImage: "sparkles") }
            ModulesSettingsView()
                .tabItem { Label("View Modules", systemImage: "puzzlepiece.extension") }
            OpenSourceSettingsView()
                .tabItem { Label("Open Source", systemImage: "shippingbox") }
        }
        .frame(width: 576)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The window's look: a theme picked once, painting the columns, the
/// list, and the writing page together.
private struct AppearanceSettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Form {
            Section {
                Picker("Theme", selection: $state.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.label).tag(theme)
                    }
                }
                .pickerStyle(.inline)
            } header: {
                Text("Appearance")
            } footer: {
                Text("Gentle is the design's quiet greys — soft columns, grey buttons, an off-white page. Darker keeps the same design a shade deeper throughout. Warm and Cool are tinted — a soft ivory or a cool slate — and bring their own dark mode, following the system between a light and a dark shade. High Contrast is black text on white throughout, the buttons outlined.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Sidebar", selection: $state.sidebarLayout) {
                    ForEach(SidebarLayout.allCases) { layout in
                        Text(layout.label).tag(layout)
                    }
                }
                .pickerStyle(.inline)
            } header: {
                Text("Sidebar")
            } footer: {
                Text("Small is the pared-down column — the head, Actions, and Views. Full carries the whole catalog: Library, Digest, Filed, and Transcripts and Draft Letters at the top.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Note Layout", selection: $state.noteLayout) {
                    ForEach(NoteLayout.allCases) { layout in
                        Text(layout.label).tag(layout)
                    }
                }
                .pickerStyle(.inline)
            } header: {
                Text("Note Layout")
            } footer: {
                Text("In the list, a clicked note grows in place to hold all its words — still the writing page — with the controls on the right. The other layouts open the note in its own pane, the controls beside it or under it. Documents that read rather than write always open in their own pane.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Articles shelf", selection: $state.articlesShelfLabel) {
                    Text("Articles").tag("Articles")
                    Text("Papers").tag("Papers")
                }
                .pickerStyle(.inline)
            } header: {
                Text("Library")
            } footer: {
                Text("What the Library's shelf of non-book works calls itself in the sidebar — your community's word for them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Stepper(value: $state.listTextSize, in: 10...20, step: 1) {
                    Text("List text size: \(Int(state.listTextSize)) pt")
                }
                Toggle("Dim the list while writing", isOn: $state.dimsListWhileEditing)
            } header: {
                Text("Notes List")
            } footer: {
                Text("The size of the list's rows in the In-the-list layout — the title and the body's first words, set in New York, the body's own type. Dimming fades the other rows to grey while a note is being written, so the open one stands out — off by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Who is reading — the user's card: the full public identity, kept in
/// the shared folder as an ordinary Origami document, exactly as the
/// phone keeps it. A bare name is never asked for; the name documents
/// credit, and attention lists match against, is the card's. Plus the
/// people whose documents this library declines to show.
private struct AuthorSettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.supportsImagePlayground) private var supportsImagePlayground
    /// How a photograph is processed when it joins a contact record —
    /// the style and prompt Image Playground draws with, carried over
    /// from Digital Letters so both apps draw the community alike.
    @AppStorage(AppSettings.portraitStyleKey)
    private var portraitStyle = PortraitStyle.illustration.rawValue
    @AppStorage(AppSettings.portraitPromptKey)
    private var portraitPrompt = PortraitStyle.defaultConcept
    @AppStorage(AppSettings.portraitInstantProcessingKey)
    private var instantProcessing = false
    @State private var card = IdentityCard()
    @State private var loadedCardID: String?
    /// A newly picked photograph, held until Save Card processes it
    /// into the shared folder.
    @State private var pendingPhotoData: Data?
    @State private var muteName = ""
    /// The ORCID lookup in flight, its candidates when several people
    /// match, and its last failure.
    @State private var searchingOrcid = false
    @State private var orcidMatches: [OrcidLookup.Match] = []
    @State private var showingOrcidMatches = false
    @State private var orcidError: String?

    /// How the portrait pipeline stands on this Mac, in a sentence.
    private var portraitsFooter: String {
        if !supportsImagePlayground {
            "Cartoon portraits need Apple Intelligence, which is not available on this Mac. Photos added to contact records are shown as-is."
        } else if !state.portraits.supportsAutomaticGeneration {
            "This Mac only allows cartoon portraits through the Image Playground window, so each is drawn from the person's form — this style and prompt are pre-set there. The original photos are never altered."
        } else {
            "Photos added to a contact record are turned into cartoon portraits, drawn on this Mac by Apple's Image Playground using this style and prompt. Changing the style re-draws every portrait from its original photo — the photos themselves are never altered, and an AI's logo is never processed."
        }
    }

    var body: some View {
        @Bindable var state = state
        Form {
            if state.ownCard == nil && !state.cards.isEmpty {
                Section {
                    ForEach(state.cards) { cardDoc in
                        LabeledContent(cardDoc.author) {
                            Button("This Is Me") { state.adopt(card: cardDoc) }
                        }
                    }
                } header: {
                    Text("Cards in the Folder")
                } footer: {
                    Text("The community folder already holds these cards. Adopt yours, or fill in a new card below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                HStack(spacing: 12) {
                    photoPreview
                    Button("Choose Photo…") { choosePhoto() }
                    if pendingPhotoData != nil || !card.photoFileName.isEmpty {
                        Button("Remove Photo") {
                            pendingPhotoData = nil
                            card.photoFileName = ""
                        }
                    }
                }
                TextField("Personal Title", text: $card.personalTitle)
                TextField("Given Name", text: $card.givenName)
                TextField("Middle Name", text: $card.middleName)
                TextField("Family Name", text: $card.familyName)
                HStack {
                    TextField("ORCID iD", text: $card.orcid)
                    if searchingOrcid {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("Search & Fill In") { searchOrcid() }
                        .disabled(searchingOrcid || !canSearchOrcid)
                        .help("Ask the public ORCID registry — by iD when one is entered, by name otherwise — and fill the card in")
                        .popover(isPresented: $showingOrcidMatches, arrowEdge: .trailing) {
                            orcidMatchList
                        }
                }
                if let orcidError {
                    Text(orcidError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                TextField("Affiliation", text: $card.affiliation)
                Button("Save Card") { state.saveCard(card, photoData: pendingPhotoData) }
                    .disabled(card.displayName.isEmpty)
            } header: {
                Text("Your Card")
            } footer: {
                Text("Your public identity — nothing on the card is private. It is kept in the shared folder as an ordinary Origami document, so the phone and every other app read the same record. The photograph is processed to a small square, stored in the folder under the card's id, and named on the card. Documents credit the card's name as their author, attention lists are matched against it, and exports carry its ORCID iD and affiliation in Visual-Meta.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Cartoon style", selection: $portraitStyle) {
                    ForEach(PortraitStyle.allCases) { style in
                        Text(style.label).tag(style.rawValue)
                    }
                }
                .onChange(of: portraitStyle) {
                    state.portraits.restyleAllPortraits()
                }
                TextField("Portrait prompt", text: $portraitPrompt, axis: .vertical)
                    .lineLimit(2...4)
                if portraitPrompt != PortraitStyle.defaultConcept {
                    Button("Reset Prompt to Default") {
                        portraitPrompt = PortraitStyle.defaultConcept
                    }
                }
                Toggle("Process photos the moment they are added",
                       isOn: $instantProcessing)
                if state.portraits.isRestyling {
                    ProgressView(value: Double(state.portraits.restyleDone),
                                 total: Double(max(state.portraits.restyleTotal, 1))) {
                        Text("Re-drawing portraits… \(state.portraits.restyleDone) of \(state.portraits.restyleTotal)")
                            .font(.caption)
                    }
                } else if state.portraits.supportsAutomaticGeneration {
                    Button("Redo All Portraits") {
                        state.portraits.restyleAllPortraits()
                    }
                }
            } header: {
                Text("Contact Portraits")
            } footer: {
                Text(portraitsFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                if state.mutedAuthors.isEmpty {
                    Text("No one is muted.")
                        .foregroundStyle(.secondary)
                }
                ForEach(state.mutedAuthors, id: \.self) { mutedName in
                    LabeledContent(mutedName) {
                        Button("Unmute") {
                            state.mutedAuthors.removeAll { $0 == mutedName }
                        }
                    }
                }
                HStack {
                    TextField("Name to mute", text: $muteName)
                    Button("Mute") {
                        let trimmed = muteName.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty, !state.isMuted(trimmed) else { return }
                        state.mutedAuthors.append(trimmed)
                        muteName = ""
                    }
                    .disabled(muteName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Muted People")
            } footer: {
                Text("Documents from muted people are not shown in the library lists. Their files stay in the library folder untouched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadCard)
        .onChange(of: state.ownCard?.id) { loadCard() }
    }

    /// Prefills the fields from the user's card in the folder — also when
    /// the scan or an adoption brings one in after the pane opened.
    private func loadCard() {
        guard let own = state.ownCard, own.id != loadedCardID else { return }
        loadedCardID = own.id
        card = IdentityCard(doc: own)
    }

    // MARK: The ORCID lookup

    /// Something to ask by: an iD in the field, or a name on the card.
    private var canSearchOrcid: Bool {
        !OrcidLookup.normalizedID(from: card.orcid).isEmpty
            || !card.givenName.trimmingCharacters(in: .whitespaces).isEmpty
            || !card.familyName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Asks the public registry — by iD when the field holds one, by the
    /// card's name otherwise. One match fills the card straight in;
    /// several open as a list to choose from.
    private func searchOrcid() {
        orcidError = nil
        searchingOrcid = true
        let id = OrcidLookup.normalizedID(from: card.orcid)
        let given = card.givenName.trimmingCharacters(in: .whitespaces)
        let family = card.familyName.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                let matches = try await OrcidLookup.search(
                    orcid: id.isEmpty ? nil : id, givenName: given, familyName: family)
                if matches.isEmpty {
                    orcidError = id.isEmpty
                        ? "ORCID found no one by that name."
                        : "ORCID found no record with that iD."
                } else if matches.count == 1 {
                    fill(from: matches[0])
                } else {
                    orcidMatches = matches
                    showingOrcidMatches = true
                }
            } catch {
                orcidError = "Could not reach ORCID: \(error.localizedDescription)"
            }
            searchingOrcid = false
        }
    }

    /// The registry's record joins the card: the iD always, the rest
    /// only where the card is blank — typed details are never clobbered.
    private func fill(from match: OrcidLookup.Match) {
        showingOrcidMatches = false
        card.orcid = match.orcid
        if card.givenName.trimmingCharacters(in: .whitespaces).isEmpty {
            card.givenName = match.givenNames
        }
        if card.familyName.trimmingCharacters(in: .whitespaces).isEmpty {
            card.familyName = match.familyNames
        }
        if card.affiliation.trimmingCharacters(in: .whitespaces).isEmpty,
           let institution = match.institutions.first {
            card.affiliation = institution
        }
    }

    /// Several people answered to the name: each with iD and
    /// institutions, one click to be the one.
    private var orcidMatchList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text("Which one is you?")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                ForEach(orcidMatches) { match in
                    Button {
                        fill(from: match)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(match.displayName.isEmpty ? match.orcid : match.displayName)
                                .fontWeight(.medium)
                            Text(match.orcid)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !match.institutions.isEmpty {
                                Text(match.institutions.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                }
            }
            .padding(12)
        }
        .frame(width: 340)
        .frame(maxHeight: 320)
    }

    /// The photograph as the card will carry it: the newly picked one,
    /// else the one already in the shared folder, else a placeholder.
    @ViewBuilder private var photoPreview: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        Group {
            if let pendingPhotoData, let image = NSImage(data: pendingPhotoData) {
                Image(nsImage: image).resizable().scaledToFill()
            } else if let url = card.photoURL(in: state.index.folderURL),
                      let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    shape.fill(.quaternary)
                    Image(systemName: "person")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(shape)
    }

    private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a photograph for your card. It is processed to a small square and shared with the folder."
        guard panel.runModal() == .OK, let url = panel.url,
              let raw = try? Data(contentsOf: url) else { return }
        // Processed the moment it is added — the preview shows the
        // square the folder will carry, not the original.
        pendingPhotoData = CardPhoto.processed(from: raw) ?? raw
    }
}

/// Where home and work are, and what places are called: the full place
/// name a note stores stays in the note — these only teach the display
/// to say "Home", "Work", or an alias when a location matches. A
/// private reading preference, like muting: never written into any
/// document.
private struct LocationsSettingsView: View {
    @Environment(AppState.self) private var state
    @AppStorage(AppLocations.homeKey) private var homeLocation = ""
    @AppStorage(AppLocations.workKey) private var workLocation = ""
    @State private var aliasEntries: [AliasEntry] = []

    private struct AliasEntry: Identifiable {
        let location: String
        var alias: String
        var id: String { location }
    }

    var body: some View {
        Form {
            Section {
                locationField("Home", text: $homeLocation)
                locationField("Work", text: $workLocation)
            } footer: {
                Text("Notes keep the full place name they were captured with. Wherever a location is shown, one matching these addresses displays simply as Home or Work — the note itself is untouched, so others still read the real place. The clock offers the last places notes carried, so nothing needs typing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                if aliasEntries.isEmpty {
                    Text("No aliases yet. Click a note's location in the options column and change the text — the note keeps its real place, and the new text becomes how it is displayed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach($aliasEntries) { $entry in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            TextField("Alias", text: $entry.alias)
                                .onSubmit { save(entry) }
                            Text(entry.location)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            AppLocations.setAlias(nil, for: entry.location)
                            reload()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("Remove the alias — the full place name shows again")
                    }
                }
            } header: {
                Text("Aliases")
            } footer: {
                Text("Each alias renames one stored place for display, the way Home and Work do. Press Return after editing a name to keep it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                if state.localities.localities.isEmpty {
                    Text("No named localities yet. Name one on the phone — Settings ▸ Name Present Locality — and it appears here once the folder syncs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(state.localities.localities) { locality in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(locality.name)
                        if !locality.tail.isEmpty {
                            Text(locality.tail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Named Localities")
            } footer: {
                Text("Nicknames you gave places on the phone, kept with the locality found there. Read-only on the Mac — you can refer to a nickname and the system knows where it is; naming happens on the phone, where the precise fix is taken.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
    }

    /// The field plus the last ten places notes carried — picked, not
    /// typed.
    private func locationField(_ label: String, text: Binding<String>) -> some View {
        HStack {
            TextField(label, text: text, prompt: Text("Full place name"))
            if !state.recentLocations.isEmpty {
                Menu {
                    ForEach(state.recentLocations, id: \.self) { location in
                        Button(location) { text.wrappedValue = location }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Pick from the last places notes carried")
            }
        }
    }

    private func reload() {
        aliasEntries = AppLocations.aliases
            .map { AliasEntry(location: $0.key, alias: $0.value) }
            .sorted { $0.location.localizedCaseInsensitiveCompare($1.location) == .orderedAscending }
    }

    private func save(_ entry: AliasEntry) {
        AppLocations.setAlias(entry.alias, for: entry.location)
        reload()
    }
}

/// Where the library is.
private struct LibrarySettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Form {
            Section {
                LabeledContent("Community Folder") {
                    Text(state.index.folderURL?.path ?? "Not set")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                Button("Choose Community Folder…") { chooseFolder() }
            } footer: {
                Text("The shared folder of Origami Documents that is the library — typically an iCloud folder your community publishes into. The folder of documents is the library; choosing a different folder changes what the whole app shows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Reader Library") {
                    Text(state.readerLibraryURL?.path ?? "Not set")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                Button("Choose Reader Library…") { chooseReaderLibrary() }
                Button("Scan Now") { state.scanReaderLibrary() }
                    .disabled(state.readerLibraryURL == nil)
                Button("Re-scan Shelf") { state.reharvestSources() }
                    .disabled(state.readerLibraryURL == nil)
                    .help("Re-reads every shelved source's PDF, refreshing titles, authors, abstracts, and margin notes the first scans may have missed")
            } footer: {
                Text("Where Reader keeps its PDFs. Knowledge Space reads each PDF's Visual-Meta — parsed from the end, as the format instructs — and every find becomes a source on the shelf, pointing back at its PDF so it opens in Reader. Scanned quietly at launch and on Scan Now; the PDFs themselves are never moved or changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Digest Folder") {
                    Text(state.digestSourceURL?.path ?? "Not set")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                Button("Choose Folder to Digest…") { chooseDigestSource() }
                Button(digestButtonLabel) { state.scanDigestSource() }
                    .disabled(state.digestSourceURL == nil || state.digestScanRunning)
            } footer: {
                Text("Any folder of your own documents — Documents itself, or narrower. Each readable file (PDF, text, Markdown, RTF, HTML, Word) becomes a digest note: a summary by the on-device model where it can read the words, with Open Original always a click away. Digests live in the community folder's Digest folder and appear only in the sidebar's Digest section. The originals are read, never moved or changed; nothing leaves the Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Delete All Archived…", role: .destructive) {
                    state.deleteAllArchived()
                }
                .disabled(state.archivedCount == 0)
            } header: {
                Text("Archive")
            } footer: {
                Text("Filing a note under Archived hides it without removing it. This empties the Archive: all \(state.archivedCount) currently archived move to the Trash — recoverable there, but gone from the shared folder for everyone who syncs it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// The Digest button wears its own progress while it works.
    private var digestButtonLabel: String {
        if let progress = state.digestProgress {
            return "Digesting \(progress.done + 1) of \(progress.total)…"
        }
        return "Digest Now"
    }

    private func chooseDigestSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder of documents to digest — your Documents folder, or any other."
        panel.prompt = "Grant"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.chooseDigestSource(url)
    }

    private func chooseReaderLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder where Reader keeps its PDFs (the Reader Library)."
        panel.prompt = "Grant"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.chooseReaderLibrary(url)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the community folder containing Origami Documents (.liquid.json)."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.chooseFolder(url)
    }
}

/// The prompts behind the AI views, fully user-owned. Every AI view runs
/// on this Mac only — no text leaves it. One editor, a picker to choose
/// which view's prompt it edits — the list grows as AI views do.
private struct AISettingsView: View {
    @AppStorage(AppSettings.aiInsightsPromptKey) private var insightsPrompt = AIInsights.defaultPrompt
    @AppStorage(AppSettings.aiThemesPromptKey) private var themesPrompt = Themes.defaultPrompt
    @AppStorage(AppSettings.aiOpenQuestionsPromptKey) private var questionsPrompt = OpenQuestions.defaultPrompt
    @AppStorage(AppSettings.aiDisagreementsPromptKey) private var disagreementsPrompt = Disagreements.defaultPrompt
    @AppStorage(AppSettings.aiAgreementsPromptKey) private var agreementsPrompt = Agreements.defaultPrompt
    @AppStorage(AppSettings.aiStrangerChallengePromptKey) private var strangerChallengePrompt = Stranger.defaultChallengePrompt
    @AppStorage(AppSettings.aiStrangerSupportPromptKey) private var strangerSupportPrompt = Stranger.defaultSupportPrompt
    @State private var selection = "AI Insights"

    private var prompt: Binding<String> {
        switch selection {
        case "Themes": $themesPrompt
        case "Open Questions": $questionsPrompt
        case "Agreements": $agreementsPrompt
        case "Disagreements": $disagreementsPrompt
        case "The Stranger — Challenge": $strangerChallengePrompt
        case "The Stranger — Support": $strangerSupportPrompt
        default: $insightsPrompt
        }
    }

    private var defaultValue: String {
        switch selection {
        case "Themes": Themes.defaultPrompt
        case "Open Questions": OpenQuestions.defaultPrompt
        case "Agreements": Agreements.defaultPrompt
        case "Disagreements": Disagreements.defaultPrompt
        case "The Stranger — Challenge": Stranger.defaultChallengePrompt
        case "The Stranger — Support": Stranger.defaultSupportPrompt
        default: AIInsights.defaultPrompt
        }
    }

    private var note: String {
        switch selection {
        case "Themes":
            "Names the themes shown in the Themes view. The response is constrained to a list of themes, each grounded in document addresses — addresses that don't exist in the library are dropped."
        case "Open Questions":
            "Names what the community has not settled. The response is constrained to a list of questions, each grounded in real document addresses."
        case "Agreements":
            "Names where documents genuinely converge. An agreement survives only when at least two real documents hold the shared position — one document cannot agree with itself."
        case "Disagreements":
            "Names where documents genuinely pull apart. Each dispute keeps only sides grounded in real documents — both sides must survive or the dispute is dropped."
        case "The Stranger — Challenge":
            "The Stranger in challenge mode: names what the community believes together but has never defended, with the strongest honest case against. Every finding is grounded in real document addresses or dropped."
        case "The Stranger — Support":
            "The Stranger in support mode: names what the community has right but undervalues. Every finding is grounded in real document addresses or dropped."
        default:
            "The AI Insights report. Citing documents by bracketed address makes the model's references live links."
        }
    }

    /// The one honest readout of the on-device model's standing —
    /// every AI feature in the app runs on it.
    private var modelAvailability: String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return "Available — Apple Intelligence's on-device model. Everything AI in this app runs on it; nothing leaves this Mac."
        case .unavailable(.deviceNotEligible):
            return "Unavailable — this Mac does not support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Unavailable — Apple Intelligence is switched off in System Settings."
        case .unavailable(.modelNotReady):
            return "Unavailable — the model is still downloading; it becomes available on its own."
        case .unavailable:
            return "Unavailable on this Mac."
        }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("On-device model") {
                    Text(modelAvailability)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Model")
            }
            Section {
                Picker("Prompt", selection: $selection) {
                    ForEach(["AI Insights", "Themes", "Open Questions", "Agreements",
                             "Disagreements",
                             "The Stranger — Challenge", "The Stranger — Support"], id: \.self) {
                        Text($0)
                    }
                }
                .pickerStyle(.menu)
                TextEditor(text: prompt)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 260)
            } header: {
                Text("AI View Prompts")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Runs on this Mac only — no text leaves it. The library's documents are appended after the prompt, newest first, with typed links passed as marked metadata and Visual-Meta appendices excluded as content. \(note)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Reset to Default") { prompt.wrappedValue = defaultValue }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Views are exchangeable modules — this tab explains how to write and
/// share one, and lists what's installed.
private struct ModulesSettingsView: View {
    @State private var xcodeExportID = LibraryViewRegistry.modules.first?.id ?? ""
    @State private var archiveExportID = LibraryViewRegistry.modules.first?.id ?? ""
    @State private var importedModules = ModuleExchange.importedArchives()
    @State private var shareNote: String?
    @State private var showsCreateGuide = false

    var body: some View {
        Form {
            Section {
                Text("Every view in the sidebar's Views section is a module: one Swift file anyone can write, share, and install. Views are how a community grows its own ways of seeing — the documents stay the same; the ways of looking multiply.")
                    .font(.callout)
            }
            Section("Installed Views") {
                // A fixed window of about five rows; the rest scroll.
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(LibraryViewRegistry.modules) { module in
                            HStack {
                                Label(module.name, systemImage: module.systemImage)
                                Spacer()
                                Text(module.id)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 5)
                            if module.id != LibraryViewRegistry.modules.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                .frame(height: 145)
            }
            shareSection
            if !importedModules.isEmpty {
                importedSection
            }
            Section {
                Button("Create Your Own…") { showsCreateGuide = true }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showsCreateGuide) { createGuide }
    }

    /// The module-writing recipe, shown on request rather than crowding
    /// the settings pane.
    private var createGuide: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create Your Own View")
                .font(.headline)
            Text("""
            1.  Write a SwiftUI view in one file. Read the library through the environment model — the document index, backlinks, and the ready-made derivations in LibraryInsights. Navigate with the same calls every view uses: openInLibrary, open(doc, fragment:), openTranspointing.
            2.  At the bottom of the file, declare a LibraryViewModule: an id, a sidebar name, an SF Symbol, and how to build its panes.
            3.  Add that module to LibraryViewRegistry.modules — one line. The sidebar entry, selection, and routing follow automatically.

            To share a view, send the file. To install one, drop it into the project and add its registry line. The full contract is documented in LibraryViewModule.swift.
            """)
            .font(.callout)
            HStack {
                Button("Copy Starter Module") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(Self.starterTemplate, forType: .string)
                }
                .help("Puts a compilable starter view module on the clipboard")
                Spacer()
                Button("Done") { showsCreateGuide = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    /// Sharing: a module leaves as a Swift file (for another user's Xcode
    /// project) or as a .origamiview archive (for another Knowledge Space
    /// or Origami Text), and either kind imports back here.
    @ViewBuilder private var shareSection: some View {
        Section {
            Picker("For Xcode", selection: $xcodeExportID) {
                ForEach(LibraryViewRegistry.modules) { module in
                    Text(module.name).tag(module.id)
                }
            }
            Button("Export Swift File…") {
                export(id: xcodeExportID, asSwift: true)
            }
            Divider()
            Picker("As Module Archive", selection: $archiveExportID) {
                ForEach(LibraryViewRegistry.modules) { module in
                    Text(module.name).tag(module.id)
                }
            }
            Button("Export View Module…") {
                export(id: archiveExportID, asSwift: false)
            }
            Divider()
            Button("Import Module…") { importModule() }
            if let shareNote {
                Text(shareNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Share")
        } footer: {
            Text("A Swift file goes into another user's Xcode project (plus one registry line). A .origamiview file imports straight into another Knowledge Space or Origami Text: a module this build already contains becomes shareable from here; a new one is kept ready for its pass through Xcode.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Modules brought in with Import: running if this build contains
    /// their code, otherwise held with their source ready to export.
    private var importedSection: some View {
        Section("Imported Modules") {
            ForEach(importedModules) { archive in
                LabeledContent {
                    HStack(spacing: 10) {
                        Text(ModuleExchange.isActive(archive) ? "Active" : "Awaiting build")
                            .font(.caption)
                            .foregroundStyle(ModuleExchange.isActive(archive)
                                             ? AnyShapeStyle(.green) : AnyShapeStyle(.orange))
                        Button("Export Swift File…") {
                            ModuleExchange.exportSwiftFile(archive)
                        }
                        .controlSize(.small)
                        Button(role: .destructive) {
                            ModuleExchange.removeImported(archive)
                            importedModules = ModuleExchange.importedArchives()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .controlSize(.small)
                    }
                } label: {
                    Label(archive.name, systemImage: archive.systemImage)
                }
            }
        }
    }

    private func export(id: String, asSwift: Bool) {
        guard let module = LibraryViewRegistry.module(id: id) else { return }
        guard let archive = ModuleExchange.archive(for: module) else {
            shareNote = "No source is available for “\(module.name)” in this build — regenerate ModuleSources.json."
            return
        }
        shareNote = nil
        if asSwift {
            ModuleExchange.exportSwiftFile(archive)
        } else {
            ModuleExchange.exportOrigamiView(archive)
        }
    }

    private func importModule() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [ModuleExchange.origamiViewType, .swiftSource]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a .origamiview module or a Swift view-module file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let archive = try ModuleExchange.importModule(at: url)
            importedModules = ModuleExchange.importedArchives()
            shareNote = ModuleExchange.isActive(archive)
                ? "“\(archive.name)” imported — its view is part of this build and running."
                : "“\(archive.name)” imported — a new module runs after its Swift file is added to the Xcode project (export it from the list below)."
        } catch {
            shareNote = error.localizedDescription
        }
    }

    private static let starterTemplate = """
    import SwiftUI

    /// My View: <what it shows, and the cognitive job it does>.
    struct MyCommunityView: View {
        @Environment(AppModel.self) private var model

        var body: some View {
            List {
                ForEach(model.index.timeline) { entry in
                    Button {
                        model.openInLibrary(entry.doc)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.doc.title)
                            Text(entry.doc.author)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    extension MyCommunityView {
        /// Install by adding `MyCommunityView.module` to
        /// LibraryViewRegistry.modules.
        @MainActor static let module = LibraryViewModule(
            id: "my-view",
            name: "My View",
            systemImage: "sparkles",
            makeContent: { AnyView(MyCommunityView()) }
        )
    }
    """
}

/// The documents that define the project — the format specification and
/// the view-module recipe — bundled with the app and opened from here.
private struct OpenSourceSettingsView: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("The Origami Document Format") {
                    Button("Open") { open("ORIGAMI-DOCUMENT-FORMAT") }
                }
                LabeledContent("Views Are Yours to Make") {
                    Button("Open") { open("VIEW-MODULES") }
                }
            } footer: {
                Text("The complete .liquid.json specification, self-contained, and the recipe for writing a view module. Both open in your default Markdown app. The format and the view modules are shared with Origami Text — a document, or a view, travels between the apps unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func open(_ resource: String) {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "md") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - The ORCID registry

/// The public ORCID registry, asked through its expanded search — one
/// endpoint answers both questions the card can pose: "who carries this
/// iD?" and "which iDs answer to this name?". Public API, no key.
private enum OrcidLookup {

    struct Match: Identifiable {
        let orcid: String
        let givenNames: String
        let familyNames: String
        let institutions: [String]
        var id: String { orcid }
        var displayName: String {
            [givenNames, familyNames]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
    }

    enum LookupError: LocalizedError {
        case badResponse
        var errorDescription: String? { "the registry did not answer as expected." }
    }

    /// The bare iD out of whatever was typed or pasted — an orcid.org
    /// URL loses its prefix; anything not shaped like an iD comes back
    /// empty so the search falls through to the name.
    static func normalizedID(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let candidate = trimmed.contains("/")
            ? trimmed.split(separator: "/").last.map(String.init) ?? ""
            : trimmed
        let pattern = /^\d{4}-\d{4}-\d{4}-\d{3}[\dX]$/
        return candidate.wholeMatch(of: pattern) != nil ? candidate : ""
    }

    static func search(orcid: String?, givenName: String, familyName: String) async throws -> [Match] {
        var terms: [String] = []
        if let orcid, !orcid.isEmpty {
            terms.append("orcid:\(orcid)")
        } else {
            if !givenName.isEmpty { terms.append("given-names:\(quoted(givenName))") }
            if !familyName.isEmpty { terms.append("family-name:\(quoted(familyName))") }
        }
        var components = URLComponents(string: "https://pub.orcid.org/v3.0/expanded-search/")!
        components.queryItems = [URLQueryItem(name: "q", value: terms.joined(separator: " AND ")),
                                 URLQueryItem(name: "rows", value: "10")]
        guard let url = components.url else { throw LookupError.badResponse }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw LookupError.badResponse
        }
        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        return (decoded.expandedResult ?? []).compactMap { result in
            guard let orcid = result.orcidID, !orcid.isEmpty else { return nil }
            return Match(orcid: orcid,
                         givenNames: result.givenNames ?? "",
                         familyNames: result.familyNames ?? "",
                         institutions: result.institutionName ?? [])
        }
    }

    /// A name as a quoted search phrase, its own quotes escaped.
    private static func quoted(_ text: String) -> String {
        "\"\(text.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private struct SearchResponse: Decodable {
        let expandedResult: [Result]?
        enum CodingKeys: String, CodingKey { case expandedResult = "expanded-result" }

        struct Result: Decodable {
            let orcidID: String?
            let givenNames: String?
            let familyNames: String?
            let institutionName: [String]?
            enum CodingKeys: String, CodingKey {
                case orcidID = "orcid-id"
                case givenNames = "given-names"
                case familyNames = "family-names"
                case institutionName = "institution-name"
            }
        }
    }
}
#endif
