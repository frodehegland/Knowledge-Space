import SwiftUI

/// A note's page: the words, editable in place — no Edit, no Done. The
/// buffer seeds once per note and saves itself: a moment after typing
/// pauses, on leaving the note, and when the app resigns. Every write
/// goes through one path — metadata blocks (Visual-Meta, analyses)
/// reattached untouched, a derived title following the words, citation
/// links re-detected, the file written atomically.
///
/// The same note edited elsewhere meanwhile (the phone, through the
/// shared folder) is never clobbered silently: an external change
/// arriving while this page is clean is adopted quietly; one arriving
/// while words were typed here is preserved as its own "(conflict
/// copy)" note before this page's words are written. Nothing is lost,
/// and nobody is asked anything.
struct NoteWritingView: View {
    @Environment(AppState.self) private var state
    @Environment(\.scenePhase) private var scenePhase
    let doc: LiquidDoc
    /// The text measure — nil reflows with the pane — and whether the
    /// page stands at the pane's left (the window's reading column) or
    /// its center (full screen).
    var measure: CGFloat? = nil
    var centersContent: Bool = false

    @State private var text = ""
    /// What the buffer was seeded from — "unchanged" means text == baseText.
    @State private var baseText = ""
    /// The file's bytes at seeding, for detecting edits from elsewhere.
    @State private var baseDiskData: Data?
    @State private var loaded = false
    @State private var autosave: Task<Void, Never>?
    @FocusState private var writing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextEditor(text: $text)
                .font(.system(size: 17, design: .serif))
                .lineSpacing(6)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 20)
                .padding(.top, 33)   // the note's single empty line
                .padding(.bottom, 16)
                .frame(maxWidth: measure ?? .infinity, alignment: .leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: centersContent ? .top : .topLeading)
                .focused($writing)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Write. A blank line starts a new paragraph; # starts a heading; **bold** and *italic* read as written.")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 26)
                            .padding(.top, 33)
                            .allowsHitTesting(false)
                    }
                }
            backlinksSection
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            text = Self.editingText(of: doc)
            baseText = text
            baseDiskData = try? Data(contentsOf: doc.fileURL)
            // A fresh, empty note invites the first words at once.
            if text.isEmpty { writing = true }
        }
        .onChange(of: text) {
            guard loaded, text != baseText else { return }
            autosave?.cancel()
            autosave = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                save()
            }
        }
        // The note changed elsewhere (the phone, a sync): while this
        // page is clean, adopt the newer words quietly.
        .onChange(of: doc) { adoptExternalIfClean() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { save() }
        }
        .onDisappear { save() }
    }

    // MARK: Backlinks

    private var backlinks: [BacklinkRef] {
        state.index.backlinks[doc.id] ?? []
    }

    @ViewBuilder private var backlinksSection: some View {
        if !backlinks.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                Text("Backlinks")
                    .font(.system(size: 15, weight: .bold, design: .serif))
                ForEach(backlinks, id: \.self) { ref in
                    if let entry = state.index.byID[ref.fromID] {
                        Button {
                            state.open(id: ref.fromID)
                        } label: {
                            HStack(spacing: 6) {
                                Text(entry.doc.title)
                                    .underline()
                                if let label = DocumentRelation.from(rel: ref.rel)?.bylineLabel {
                                    Text(label.lowercased())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .font(.system(size: 13))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 16)
            .frame(maxWidth: measure ?? .infinity, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: centersContent ? .center : .leading)
        }
    }

    // MARK: The text

    /// The words alone: the Visual-Meta appendix and analysis blocks are
    /// metadata, not writing.
    private nonisolated static func hiddenIDs(of doc: LiquidDoc) -> Set<String> {
        doc.visualMetaParagraphIDs.union(doc.analysisParagraphIDs)
    }

    private nonisolated static func contentParagraphs(of doc: LiquidDoc) -> [LiquidDoc.Paragraph] {
        let hidden = hiddenIDs(of: doc)
        return (doc.body ?? []).filter { !hidden.contains($0.id) }
    }

    private nonisolated static func editingText(of doc: LiquidDoc) -> String {
        contentParagraphs(of: doc).map { paragraph in
            let prefix: String = switch paragraph.heading {
            case 1: "# "
            case 2: "## "
            case 3: "### "
            default: ""
            }
            return prefix + paragraph.text
        }
        .joined(separator: "\n\n")
    }

    /// The first four words, standing in for the subject a voice note
    /// never really has — the same rule the phone uses.
    private nonisolated static func derivedTitle(for text: String) -> String {
        let title = text.split(whereSeparator: \.isWhitespace)
            .prefix(4)
            .joined(separator: " ")
        return title.isEmpty ? "Untitled" : title
    }

    // MARK: Saving

    private func save() {
        autosave?.cancel()
        guard loaded, text != baseText else { return }

        // The file changed under us while words were typed here: keep
        // the other version as its own note before writing ours.
        let diskData = try? Data(contentsOf: doc.fileURL)
        if let diskData, let baseDiskData, diskData != baseDiskData {
            preserveConflictCopy(diskData)
        }

        // Metadata blocks ride along untouched, after the words.
        let preserved = (doc.body ?? []).filter { Self.hiddenIDs(of: doc).contains($0.id) }
        let body = LiquidDoc.parseBody(from: text) + preserved

        // A derived title stays derived — the first four words of
        // whatever the note now says. A real title stays itself.
        let oldContent = Self.contentParagraphs(of: doc).map(\.text).joined(separator: " ")
        let titleWasDerived = doc.title == Self.derivedTitle(for: oldContent)
            || doc.title == "Untitled"
        let title = titleWasDerived
            ? Self.derivedTitle(for: text.trimmingCharacters(in: .whitespacesAndNewlines))
            : doc.title

        let updated = LiquidDoc(format: doc.format,
                                id: doc.id,
                                title: title,
                                author: doc.author,
                                created: doc.created,
                                body: body,
                                links: LiquidDoc.detectedLinks(in: body),
                                wraps: nil,
                                attention: doc.attention,
                                date: doc.date,
                                aiOnBehalf: doc.aiOnBehalf,
                                draft: doc.draft,
                                onBehalfOf: doc.onBehalfOf,
                                documentType: doc.documentType,
                                location: doc.location,
                                concepts: doc.concepts,
                                layouts: doc.layouts,
                                mapConnections: doc.mapConnections,
                                references: doc.references,
                                fileURL: doc.fileURL)
        do {
            let data = try updated.jsonData()
            try data.write(to: updated.fileURL, options: .atomic)
            baseText = text
            baseDiskData = data
            state.index.rescan()
        } catch {
            state.showNote("Could not save the note: \(error.localizedDescription)")
        }
    }

    /// The version of this note that arrived from elsewhere becomes its
    /// own note, so no words are ever lost to a race.
    private func preserveConflictCopy(_ data: Data) {
        guard let incoming = try? LiquidDoc.decode(data: data, fileURL: doc.fileURL),
              let folderURL = state.index.folderURL else { return }
        let created = Date.now
        let id = LiquidAddress.makeID(author: incoming.author, created: created) { candidate in
            state.index.byID[candidate] != nil
        }
        let copy = LiquidDoc(format: incoming.format,
                             id: id,
                             title: "\(incoming.title) (conflict copy)",
                             author: incoming.author,
                             created: created,
                             body: incoming.body,
                             links: incoming.links,
                             wraps: nil,
                             attention: incoming.attention,
                             date: incoming.date,
                             aiOnBehalf: incoming.aiOnBehalf,
                             draft: incoming.draft,
                             onBehalfOf: incoming.onBehalfOf,
                             documentType: incoming.documentType,
                             location: incoming.location,
                             fileURL: folderURL.appendingPathComponent(id)
                                 .appendingPathExtension(LiquidDoc.fileExtension))
        try? copy.jsonData().write(to: copy.fileURL, options: .atomic)
        state.showNote("This note changed elsewhere while you wrote — the other version is kept as “\(copy.title)”.")
    }

    /// A change from elsewhere, met while this page is clean: adopt it.
    /// (With local words typed, the save path preserves both instead.)
    private func adoptExternalIfClean() {
        guard loaded, text == baseText else { return }
        let fresh = Self.editingText(of: doc)
        guard fresh != baseText else { return }
        text = fresh
        baseText = fresh
        baseDiskData = try? Data(contentsOf: doc.fileURL)
    }
}
