#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImagePlayground
import Contacts

// The contact form carried over from Digital Letters, so both apps edit
// the same records the same way.

/// A person's contact record: name parts and affiliation, with ORCID
/// search to anchor the record to a canonical academic identity. Every
/// field ORCID returns is shown.
struct PersonFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @Environment(\.supportsImagePlayground) private var supportsImagePlayground
    @State var person: Person
    let heading: String
    let onSave: (Person) -> Void

    @State private var isSearching = false
    @State private var results: [ORCIDResult] = []
    @State private var searchError: String?
    @State private var hasSearched = false
    @State private var showsPhotoImporter = false
    @State private var showsPlaygroundSheet = false
    @State private var showsPhotoSearch = false
    /// Why the photograph search did not open: name and ORCID both empty.
    @State private var photoSearchNotice: String?
    /// The photograph clicked in the search sheet; adopted and processed
    /// once that sheet has closed, so the Playground sheet can present.
    @State private var pickedFoundPhoto: NSImage?
    @State private var showsContactsSearch = false
    /// The card chosen in the Contacts sheet; applied once that sheet has
    /// closed, for the same reason as the found photo above.
    @State private var pickedContact: ContactPick?
    /// Whether an added photo is processed into its cartoon immediately.
    @AppStorage(AppSettings.portraitInstantProcessingKey) private var instantProcessing = false
    /// The names of records already imported into this one and deleted.
    @State private var imported: [String] = []
    @State private var alsoSelectionID: String?
    @State private var showsDeleteConfirmation = false

    /// Whether the record is already in the directory — only a saved
    /// record offers deletion; a form for a new person has nothing to delete.
    private var isExistingRecord: Bool {
        model.people.people.contains { $0.localID == person.localID }
    }

    /// Every other name the record could import: the directory's other
    /// records, then authors in the library who have no record yet.
    private var mergeCandidates: [Person] {
        var result: [Person] = []
        var seen = Set<String>()
        for other in model.people.people
        where other.localID != person.localID
            && !person.answersTo(other.displayName) {
            result.append(other)
            seen.insert(other.displayName.lowercased())
        }
        for name in model.libraryAuthorNames {
            guard !seen.contains(name.lowercased()),
                  !person.answersTo(name),
                  model.people.person(named: name) == nil
            else { continue }
            result.append(Person(displayName: name))
        }
        return result.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private var canSearch: Bool {
        !isSearching && (!person.givenName.trimmingCharacters(in: .whitespaces).isEmpty
                         || !person.familyName.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// The optional field as an editable string; emptied text clears it.
    private var publicProfileBinding: Binding<String> {
        Binding(
            get: { person.publicProfile ?? "" },
            set: { person.publicProfile = $0.isEmpty ? nil : $0 }
        )
    }

    /// The stored aliases on one line; commas separate, empties fall away.
    private var aliasesBinding: Binding<String> {
        Binding(
            get: { (person.aliases ?? []).joined(separator: ", ") },
            set: { text in
                let names = text.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                person.aliases = names.isEmpty ? nil : names
            }
        )
    }

    /// Every address on one line; commas separate, empties fall away.
    private var emailsBinding: Binding<String> {
        Binding(
            get: { person.emails.joined(separator: ", ") },
            set: { text in
                person.emails = text.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    /// The record as an AI model: on, the form keeps to model name,
    /// company, and version, and the display name is the model's alone.
    private var aiBinding: Binding<Bool> {
        Binding(
            get: { person.isArtificial },
            set: { on in
                person.isAI = on ? true : nil
                if on {
                    // A model has one name: the person parts fold away.
                    person.middleName = ""
                    person.familyName = ""
                }
            }
        )
    }

    private var aiVersionBinding: Binding<String> {
        Binding(
            get: { person.aiVersion ?? "" },
            set: { person.aiVersion = $0.isEmpty ? nil : $0 }
        )
    }

    /// This contact is a model, not a person.
    private var aiToggle: some View {
        Toggle("AI", isOn: aiBinding)
            .toggleStyle(.button)
            .help("This contact is an AI model, not a person — the record keeps its model name, company, and version, with the company's logo for a face")
    }

    /// What the logo search looks for: the company, else the model name.
    private var logoQuery: String {
        let company = person.affiliation.trimmingCharacters(in: .whitespaces)
        return company.isEmpty
            ? person.givenName.trimmingCharacters(in: .whitespaces) : company
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(heading)
                .font(.title3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)

            Form {
                portraitSection
                Section(person.isArtificial ? "AI Model" : "Name") {
                    if person.isArtificial {
                        TextField("Model name", text: $person.givenName,
                                  prompt: Text("for example Claude"))
                        TextField("Company", text: $person.affiliation,
                                  prompt: Text("for example Anthropic"))
                        TextField("Version", text: aiVersionBinding,
                                  prompt: Text("for example 5"))
                        aiToggle
                    } else {
                        TextField("First name", text: $person.givenName)
                        TextField("Middle name", text: $person.middleName)
                        TextField("Last name", text: $person.familyName)
                        TextField("Affiliation", text: $person.affiliation)
                        HStack {
                            Button {
                                showsContactsSearch = true
                            } label: {
                                Label("Find in Contacts…", systemImage: "person.text.rectangle")
                            }
                            .help("Fill this record from your Contacts — name, email, affiliation, and photo. Contacts is only read, never changed.")
                            Spacer()
                            aiToggle
                        }
                    }
                }

                if !person.isArtificial {
                Section {
                    TextField("Aliases", text: aliasesBinding,
                              prompt: Text("Other names, comma-separated"))
                } header: {
                    Text("Also Known As")
                } footer: {
                    Text("Other spellings this person answers to. Notes naming any of these count as mentions of this person.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextField("Email", text: emailsBinding,
                              prompt: Text("name@example.org"))
                } header: {
                    Text("Mail")
                } footer: {
                    Text("Commas separate several addresses. Digital Letters posts published letters to the first while its distribution checkbox is on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextEditor(text: publicProfileBinding)
                        .font(.body)
                        .frame(minHeight: 70)
                } header: {
                    Text("Public Profile")
                } footer: {
                    Text("The person's public profile in their own words — shown on their card and their author page.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextField("ORCID iD", text: $person.orcid,
                              prompt: Text("0000-0000-0000-0000"))
                        .font(.body.monospaced())
                    HStack {
                        Button {
                            search()
                        } label: {
                            Label(isSearching ? "Searching…" : "Search ORCID",
                                  systemImage: "magnifyingglass")
                        }
                        .disabled(!canSearch)
                        if isSearching {
                            ProgressView().controlSize(.small)
                        }
                    }
                    if let searchError {
                        Text(searchError)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                    if hasSearched, results.isEmpty, searchError == nil, !isSearching {
                        Text("No ORCID records found for that name.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(results) { result in
                        resultRow(result)
                    }
                } header: {
                    Text("ORCID")
                } footer: {
                    Text("The ORCID iD is the canonical identity for this person. Search fills the record from the public ORCID registry.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !person.creditName.isEmpty || !person.otherNames.isEmpty || !person.emails.isEmpty {
                    Section("From ORCID") {
                        if !person.creditName.isEmpty {
                            LabeledContent("Credit name", value: person.creditName)
                        }
                        if !person.otherNames.isEmpty {
                            LabeledContent("Other names", value: person.otherNames.joined(separator: ", "))
                        }
                        if !person.emails.isEmpty {
                            LabeledContent("Email", value: person.emails.joined(separator: ", "))
                        }
                    }
                }

                // Two records, one person: choosing another name imports
                // everything it holds into this record — the other name
                // becomes an alias when different — and deletes the
                // other record at once.
                if !mergeCandidates.isEmpty {
                    Section {
                        Picker("Import and delete from other record:",
                               selection: $alsoSelectionID) {
                            Text("—").tag(String?.none)
                            ForEach(mergeCandidates) { candidate in
                                Text(candidate.displayName).tag(Optional(candidate.localID))
                            }
                        }
                        .onChange(of: alsoSelectionID) {
                            guard let id = alsoSelectionID,
                                  let other = mergeCandidates.first(where: { $0.localID == id })
                            else { return }
                            importAndDelete(other)
                            alsoSelectionID = nil
                        }
                        if !imported.isEmpty {
                            Text("Imported and deleted: \(imported.joined(separator: ", ")).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("Another record that is really this person. Choosing one imports everything it holds into this record — its name becomes an alias when it differs — and deletes the other record immediately.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                } // The person-only sections end here; a model needs none.
            }
            .formStyle(.grouped)

            HStack {
                if isExistingRecord {
                    Button("Delete Record", role: .destructive) {
                        showsDeleteConfirmation = true
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(person)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(person.displayName.isEmpty)
            }
            .padding(16)
        }
        // Wide enough that the portrait row's buttons never truncate.
        .frame(width: 640, height: 660)
        .confirmationDialog("Delete \(person.displayName)?",
                            isPresented: $showsDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                model.portraits.removeImages(for: person.localID)
                model.people.remove(person)
                dismiss()
            }
        } message: {
            Text("The record and its portrait are removed from People. Their notes and documents stay in the library.")
        }
        .fileImporter(isPresented: $showsPhotoImporter, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if let photo = NSImage(contentsOf: url) {
                adopt(photo)
            }
        }
        .sheet(isPresented: $showsPhotoSearch, onDismiss: {
            // Adopt after the search sheet is gone: processing may need to
            // present the Image Playground sheet in its place.
            if let photo = pickedFoundPhoto {
                pickedFoundPhoto = nil
                model.portraits.adoptPhoto(photo, for: person.localID)
                // A logo stays as it is; a person's photo is drawn into
                // its cartoon.
                if !person.isArtificial { processPortrait() }
            }
        }) {
            PhotoSearchSheet(name: person.isArtificial ? logoQuery : person.displayName,
                             orcid: person.isArtificial ? "" : person.orcid,
                             searchesLogos: person.isArtificial,
                             alsoSearch: person.isArtificial ? person.givenName : "") { photo in
                pickedFoundPhoto = photo
            }
        }
        .sheet(isPresented: $showsContactsSearch, onDismiss: {
            // Apply after the search sheet is gone: adopting the photo may
            // need to present the Image Playground sheet in its place.
            if let pick = pickedContact {
                pickedContact = nil
                apply(pick)
            }
        }) {
            ContactsSearchSheet(initialQuery: person.displayName) { pick in
                pickedContact = pick
            }
        }
        .imagePlaygroundSheet(isPresented: $showsPlaygroundSheet,
                              concepts: [.text(PortraitStyle.concept)],
                              sourceImage: sheetSourceImage) { url in
            model.portraits.adoptSheetPortrait(from: url, for: person.localID)
        }
        // Only the configured style is offered, so every portrait in the
        // community comes out in the same visual language.
        .imagePlaygroundGenerationStyle(PortraitStyle.current.playgroundStyle,
                                        in: [PortraitStyle.current.playgroundStyle])
    }

    /// Imports everything the other record holds into this one — its
    /// name becoming an alias when it differs — hands over its portrait
    /// when this record has none, and deletes the other record at once.
    private func importAndDelete(_ other: Person) {
        person = person.merged(absorbing: other)
        if model.portraits.original(for: person.localID) == nil,
           let photo = model.portraits.original(for: other.localID) {
            model.portraits.adoptPhoto(photo, for: person.localID)
        }
        model.portraits.removeImages(for: other.localID)
        model.people.remove(other)
        model.index.rescan()
        imported.append(other.displayName)
    }

    /// Stores the photo; processing into a cartoon follows only when
    /// Instant Processing is on, or when the user clicks Process — and
    /// never for an AI's logo, which is used as it is.
    private func adopt(_ photo: NSImage) {
        model.portraits.adoptPhoto(photo, for: person.localID)
        if instantProcessing, !person.isArtificial {
            processPortrait()
        }
    }

    /// Draws the cartoon from the stored photo: silently where the Mac
    /// allows it, else through the system sheet seeded with the photo.
    private func processPortrait() {
        if model.portraits.supportsAutomaticGeneration {
            model.portraits.generatePortrait(for: person.localID)
        } else if supportsImagePlayground {
            showsPlaygroundSheet = true
        }
    }

    private var sheetSourceImage: Image? {
        // The head-framed rendition, so the cartoon inherits full-head
        // framing with margin; the raw photo only if no face was found.
        (model.portraits.framedOriginal(for: person.localID)
         ?? model.portraits.original(for: person.localID))
            .map { Image(nsImage: $0) }
    }

    /// The person's face: drop or choose a photo, and Image Playground
    /// draws the cartoon portrait used everywhere. The photo is kept
    /// untouched, so the cartoon can be re-drawn in another style.
    private var portraitSection: some View {
        Section(person.isArtificial ? "Logo" : "Portrait") {
            HStack(alignment: .center, spacing: 14) {
                portraitPreview
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("Choose…") { showsPhotoImporter = true }
                        Button(person.isArtificial ? "Find Logo…" : "Find Photo…") {
                            if person.isArtificial {
                                if logoQuery.isEmpty {
                                    photoSearchNotice = "Fill in the company or model name first, so the search knows whose logo to look for."
                                } else {
                                    photoSearchNotice = nil
                                    showsPhotoSearch = true
                                }
                            } else if person.displayName.trimmingCharacters(in: .whitespaces).isEmpty,
                               person.orcid.trimmingCharacters(in: .whitespaces).isEmpty {
                                photoSearchNotice = "Fill in a name or ORCID iD first, so the search knows who to look for."
                            } else {
                                photoSearchNotice = nil
                                showsPhotoSearch = true
                            }
                        }
                        .help(person.isArtificial
                              ? "Search online for the company's logo"
                              : "Search online for a photograph of this person")
                        if model.portraits.hasOriginal(for: person.localID) {
                            if !person.isArtificial {
                                Button("Process") { processPortrait() }
                                    .disabled(isGeneratingPortrait || !supportsImagePlayground)
                            }
                            Button("Remove", role: .destructive) {
                                model.portraits.removeImages(for: person.localID)
                            }
                        }
                        if !person.isArtificial {
                            Toggle("Instant", isOn: $instantProcessing)
                                .toggleStyle(.checkbox)
                                .help("Process a photo into its cartoon portrait the moment it is added")
                        }
                    }
                    if let photoSearchNotice {
                        Text(photoSearchNotice)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    portraitStatus
                }
                Spacer()
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first, let photo = NSImage(contentsOf: url) else { return false }
                adopt(photo)
                return true
            }
        }
    }

    private var isGeneratingPortrait: Bool {
        model.portraits.generatingIDs.contains(person.localID)
    }

    private var portraitPreview: some View {
        ZStack {
            if let image = model.portraits.portrait(for: person.localID)
                ?? model.portraits.original(for: person.localID) {
                if person.isArtificial {
                    // A logo shows whole, never cropped to the frame.
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(4)
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                }
            } else {
                Circle().fill(.quaternary)
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
            }
            if isGeneratingPortrait {
                Circle().fill(.black.opacity(0.35))
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(Circle())
    }

    @ViewBuilder private var portraitStatus: some View {
        if person.isArtificial {
            Text(model.portraits.hasOriginal(for: person.localID)
                 ? "The logo is used as it is — no cartoon is drawn."
                 : "Drop an image here, choose one, or find the company's logo online.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if isGeneratingPortrait {
            Text("Drawing the cartoon portrait…")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let error = model.portraits.errors[person.localID] {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        } else if !supportsImagePlayground {
            Text("Cartoon portraits need Apple Intelligence; the photo is shown as-is.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if model.portraits.hasOriginal(for: person.localID),
                  model.portraits.portrait(for: person.localID) == nil {
            Text("Click Process to draw the cartoon portrait from this photo.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if model.portraits.portrait(for: person.localID) != nil {
            Text("Drawn from your photo in the chosen portrait style.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text(instantProcessing
                 ? "Drop a photo here or choose one — it is processed into a cartoon portrait immediately."
                 : "Drop a photo here or choose one, then click Process for the cartoon portrait.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Every field the registry returned, visible; Use adopts the record.
    private func resultRow(_ result: ORCIDResult) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text([result.givenNames, result.familyNames]
                    .filter { !$0.isEmpty }.joined(separator: " "))
                    .fontWeight(.medium)
                Text(result.orcid)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if !result.creditName.isEmpty {
                    Text("Credit name: \(result.creditName)").font(.caption)
                }
                if !result.otherNames.isEmpty {
                    Text("Other names: \(result.otherNames.joined(separator: ", "))").font(.caption)
                }
                if !result.institutions.isEmpty {
                    Text(result.institutions.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !result.emails.isEmpty {
                    Text(result.emails.joined(separator: ", ")).font(.caption)
                }
            }
            Spacer()
            Button("Use") { adopt(result) }
        }
        .padding(.vertical, 2)
    }

    /// Copies a chosen Contacts card into the record: name parts, emails
    /// (merged, never dropped), affiliation where the record has none,
    /// and the card's photo into the portrait pipeline. Contacts itself
    /// is untouched.
    private func apply(_ pick: ContactPick) {
        if !pick.givenName.isEmpty { person.givenName = pick.givenName }
        if !pick.middleName.isEmpty { person.middleName = pick.middleName }
        if !pick.familyName.isEmpty { person.familyName = pick.familyName }
        if person.affiliation.isEmpty { person.affiliation = pick.organization }
        for email in pick.emails
        where !person.emails.contains(where: { $0.caseInsensitiveCompare(email) == .orderedSame }) {
            person.emails.append(email)
        }
        if let data = pick.imageData, let photo = NSImage(data: data) {
            adopt(photo)
        }
    }

    private func adopt(_ result: ORCIDResult) {
        if !result.givenNames.isEmpty { person.givenName = result.givenNames }
        if !result.familyNames.isEmpty { person.familyName = result.familyNames }
        person.orcid = result.orcid
        person.creditName = result.creditName
        person.otherNames = result.otherNames
        person.emails = result.emails
        if person.affiliation.isEmpty {
            person.affiliation = result.institutions.first ?? ""
        }
    }

    private func search() {
        isSearching = true
        searchError = nil
        results = []
        let given = person.givenName
        let family = person.familyName
        Task {
            do {
                results = try await ORCIDClient.search(givenName: given, familyName: family)
            } catch {
                searchError = "ORCID search failed: \(error.localizedDescription)"
            }
            hasSearched = true
            isSearching = false
        }
    }
}

/// What a chosen Contacts card carries back into the record. Plain data,
/// so it crosses from the background fetch untangled.
private nonisolated struct ContactPick: Sendable {
    var givenName = ""
    var middleName = ""
    var familyName = ""
    var organization = ""
    var emails: [String] = []
    var imageData: Data?
}

/// The user's Contacts, searched by name — read-only: choosing a card
/// copies its details into the record; nothing is ever written back.
/// The first use asks macOS for permission to read Contacts.
private struct ContactsSearchSheet: View {
    let initialQuery: String
    let onPick: (ContactPick) -> Void
    @Environment(\.dismiss) private var dismiss

    private struct Match: Identifiable {
        let id: String
        let displayName: String
        let detail: String
        let thumbnail: NSImage?
        let pick: ContactPick
    }

    @State private var query = ""
    @State private var matches: [Match] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find in Contacts")
                .font(.title3)
            HStack {
                TextField("Name", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                Button("Search") { search() }
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
            }
            Group {
                if isSearching {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Searching Contacts…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 120)
                } else if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else if hasSearched, matches.isEmpty {
                    Text("No contacts match “\(query)”.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else if !hasSearched {
                    // Nothing filled in yet: the field above takes a
                    // name — or anything — and Return searches.
                    Text("Type a name — or anything — and press Return to search your Contacts.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(matches) { match in
                                matchRow(match)
                            }
                        }
                    }
                    .frame(minHeight: 120, maxHeight: 280)
                }
            }
            HStack {
                Text("Contacts is only read — choosing a card copies its details here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { dismiss() }
            }
        }
        .padding(16)
        .frame(width: 520)
        .onAppear {
            query = initialQuery
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                search()
            }
        }
    }

    private func matchRow(_ match: Match) -> some View {
        HStack(spacing: 10) {
            ZStack {
                if let thumbnail = match.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Circle().fill(.quaternary)
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(match.displayName)
                    .fontWeight(.medium)
                if !match.detail.isEmpty {
                    Text(match.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button("Use") {
                onPick(match.pick)
                dismiss()
            }
        }
        .padding(.vertical, 2)
    }

    private func search() {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        error = nil
        matches = []
        Task {
            do {
                matches = try await Self.findContacts(matching: trimmed).map { found in
                    Match(id: found.id,
                          displayName: [found.pick.givenName, found.pick.middleName,
                                        found.pick.familyName]
                              .filter { !$0.isEmpty }.joined(separator: " "),
                          detail: [found.pick.organization,
                                   found.pick.emails.joined(separator: ", ")]
                              .filter { !$0.isEmpty }.joined(separator: " · "),
                          thumbnail: found.thumbnailData.flatMap(NSImage.init(data:)),
                          pick: found.pick)
                }
            } catch {
                self.error = error.localizedDescription
            }
            hasSearched = true
            isSearching = false
        }
    }

    // MARK: The Contacts fetch

    private nonisolated struct FoundContact: Sendable {
        let id: String
        let pick: ContactPick
        let thumbnailData: Data?
    }

    private nonisolated struct ContactsAccessError: LocalizedError {
        var errorDescription: String? {
            "macOS declined access to Contacts. Allow Knowledge Space in System Settings → Privacy & Security → Contacts, then search again."
        }
    }

    /// Asks for permission on the first use, then fetches the unified
    /// cards matching the name. Off the main actor — the fetch blocks.
    private nonisolated static func findContacts(matching query: String) async throws -> [FoundContact] {
        let store = CNContactStore()
        if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
            _ = try? await store.requestAccess(for: .contacts)
        }
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            throw ContactsAccessError()
        }
        let keys = [CNContactGivenNameKey, CNContactMiddleNameKey, CNContactFamilyNameKey,
                    CNContactOrganizationNameKey, CNContactEmailAddressesKey,
                    CNContactImageDataKey, CNContactThumbnailImageDataKey] as [CNKeyDescriptor]
        let contacts = try store.unifiedContacts(
            matching: CNContact.predicateForContacts(matchingName: query),
            keysToFetch: keys)
        return contacts.map { contact in
            var pick = ContactPick()
            pick.givenName = contact.givenName
            pick.middleName = contact.middleName
            pick.familyName = contact.familyName
            pick.organization = contact.organizationName
            pick.emails = contact.emailAddresses.map { String($0.value) }
            pick.imageData = contact.imageData ?? contact.thumbnailImageData
            return FoundContact(id: contact.identifier,
                                pick: pick,
                                thumbnailData: contact.thumbnailImageData ?? contact.imageData)
        }
    }
}

/// Photographs found online for the person — up to five, from the lead
/// images of Wikipedia pages matching the name (resolved from the ORCID
/// registry when only the iD is filled in). Clicking one adopts it and
/// processing starts immediately; Cancel leaves the record untouched.
/// For an AI record the same search runs on the company's name, whose
/// page's lead image is its logo — adopted as it is.
private struct PhotoSearchSheet: View {
    let name: String
    let orcid: String
    var searchesLogos = false
    /// A second subject searched beside the name — the AI's model name
    /// beside its company, so both sets of images are offered.
    var alsoSearch: String = ""
    let onPick: (NSImage) -> Void
    @Environment(\.dismiss) private var dismiss

    private var noun: String { searchesLogos ? "Logos" : "Photographs" }

    private struct Candidate: Identifiable {
        let id: String
        let title: String
        let image: NSImage
    }
    @State private var candidates: [Candidate] = []
    @State private var isSearching = true
    @State private var error: String?
    @State private var searchedName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(searchedName.isEmpty
                 ? (searchesLogos ? "Finding a Logo" : "Finding a Photograph")
                 : "\(noun) of \(searchedName)")
                .font(.title3)
            Group {
                if isSearching {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Searching online…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 150)
                } else if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, minHeight: 150)
                } else if candidates.isEmpty {
                    Text("No \(noun.lowercased()) found for “\(searchedName)”.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 150)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(searchesLogos
                             ? "Click a logo to use it — it is kept as it is."
                             : "Click a photograph to use it — processing starts immediately.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10,
                                                     alignment: .top)],
                                  alignment: .leading, spacing: 10) {
                            ForEach(candidates) { candidate in
                                VStack(spacing: 4) {
                                    Button {
                                        onPick(candidate.image)
                                        dismiss()
                                    } label: {
                                        // A logo shows whole; a photo fills
                                        // its square. Either way the image
                                        // stays inside its button — a wide
                                        // logo's unclipped overflow would
                                        // lie over the neighbouring buttons
                                        // and swallow their clicks.
                                        Group {
                                            if searchesLogos {
                                                Image(nsImage: candidate.image)
                                                    .resizable()
                                                    .scaledToFit()
                                                    .padding(6)
                                            } else {
                                                Image(nsImage: candidate.image)
                                                    .resizable()
                                                    .scaledToFill()
                                            }
                                        }
                                        .frame(width: 96, height: 96)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .background(.quaternary.opacity(0.5),
                                                    in: RoundedRectangle(cornerRadius: 8))
                                        .contentShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Use this image (from “\(candidate.title)” on Wikipedia)")
                                    Text(candidate.title)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                        .frame(width: 96)
                                }
                            }
                        }
                    }
                }
            }
            HStack {
                Text(searchesLogos
                     ? "Logos come from the matching Wikipedia pages' own images."
                     : "Photographs are the lead images of matching Wikipedia pages.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { dismiss() }
            }
        }
        .padding(16)
        .frame(width: 580)
        .task { await load() }
    }

    private func load() async {
        do {
            var primary = name.trimmingCharacters(in: .whitespaces)
            if primary.isEmpty {
                primary = try await ORCIDClient.name(forORCID: orcid) ?? ""
            }
            var queries = [primary, alsoSearch.trimmingCharacters(in: .whitespaces)]
                .filter { !$0.isEmpty }
            // The same word twice searches once.
            if queries.count == 2,
               queries[0].caseInsensitiveCompare(queries[1]) == .orderedSame {
                queries.removeLast()
            }
            guard !queries.isEmpty else {
                error = "The ORCID record did not give a name to search for."
                isSearching = false
                return
            }
            searchedName = queries.joined(separator: " · ")
            var found: [Candidate] = []
            if searchesLogos {
                // Logos come from the matching pages' own image files;
                // keep the first six that download.
                for photo in try await PhotoSearchClient.searchLogos(terms: queries) {
                    if found.count == 6 { break }
                    guard !found.contains(where: { $0.title == photo.title }) else { continue }
                    if let image = await Self.download(photo.imageURL) {
                        found.append(Candidate(id: photo.id, title: photo.title, image: image))
                    }
                }
            } else {
                // Over-fetch, then keep the first few whose images
                // download, shared evenly between the subjects.
                let perQuery = queries.count == 1 ? 5 : 3
                for query in queries {
                    var kept = 0
                    for photo in try await PhotoSearchClient.searchPhotos(name: query) {
                        if kept == perQuery { break }
                        guard !found.contains(where: { $0.title == photo.title }) else { continue }
                        if let image = await Self.download(photo.imageURL) {
                            found.append(Candidate(id: photo.id, title: photo.title, image: image))
                            kept += 1
                        }
                    }
                }
            }
            candidates = found
        } catch {
            self.error = "Photograph search failed: \(error.localizedDescription)"
        }
        isSearching = false
    }

    private static func download(_ url: URL) async -> NSImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return NSImage(data: data)
    }
}
#endif
