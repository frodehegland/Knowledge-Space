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
    /// Inline: the note expanded in the list itself (Settings ▸
    /// Appearance, "In the list"). The editor sizes to its words and
    /// the list scrolls around it, rather than scrolling within.
    var inline: Bool = false

    @State private var text = ""
    /// What the buffer was seeded from — "unchanged" means text == baseText.
    @State private var baseText = ""
    /// The file's bytes at seeding, for detecting edits from elsewhere.
    @State private var baseDiskData: Data?
    @State private var loaded = false
    @State private var autosave: Task<Void, Never>?
    @FocusState private var writing: Bool
    #if os(macOS)
    /// Names the reader told to stay as written in this note, lowercased.
    @State private var dismissedNames: Set<String> = []
    /// A new contact begun from a typed name, presented as the form.
    @State private var newPerson: Person?
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.flowReading {
                flowedReading
            } else {
                TextEditor(text: $text)
                    .font(.system(size: 17, design: .serif))
                    .lineSpacing(6)
                    .scrollContentBackground(.hidden)
                    // Inline, the editor holds all its words and the
                    // list scrolls; in its own pane, it scrolls itself.
                    .scrollDisabled(inline)
                    .padding(.horizontal, inline ? 2 : 20)
                    .padding(.top, inline ? 6 : 33)   // the note's single empty line
                    .padding(.bottom, inline ? 6 : 16)
                    .frame(maxWidth: measure ?? .infinity, alignment: .leading)
                    .frame(maxWidth: .infinity,
                           maxHeight: inline ? nil : .infinity,
                           alignment: centersContent ? .top : .topLeading)
                    .frame(minHeight: inline ? 44 : 0)
                    .focused($writing)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("Write. A blank line starts a new paragraph; # starts a heading; **bold** and *italic* read as written.")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, inline ? 6 : 26)
                                .padding(.top, inline ? 6 : 33)
                                .allowsHitTesting(false)
                        }
                    }
            }
            if state.showsVisualMeta {
                metadataReading
            }
            #if os(macOS)
            nameSuggestionsBar
            #endif
            // Backlinks stay out of the note's in-list page — the list
            // around it is context enough; the section returns when the
            // note has a page of its own (full screen, own pane).
            if !inline {
                backlinksSection
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            text = Self.editingText(of: doc)
            baseText = text
            baseDiskData = try? Data(contentsOf: doc.fileURL)
            #if os(macOS)
            loadDismissedNames()
            #endif
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
        // The writing page stands on the design's page grey.
        .background(AppGreys.page)
        .environment(\.colorScheme, .light)
    }

    /// The metadata riding with the note — its Visual-Meta appendix and
    /// analyses, the paragraphs the editor keeps out of the writing —
    /// rendered read-only under the words at the reader's half size.
    /// Shown by the options column's Visual-Meta button; the blocks
    /// travel with the file whether or not they are shown.
    private var metadataReading: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach((doc.body ?? []).filter {
                    Self.hiddenIDs(of: doc).contains($0.id)
                }) { paragraph in
                    ParagraphView(paragraph: paragraph, isAppendix: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .frame(maxHeight: 260)
    }

    /// Flow: the same words the editor holds, rendered paragraph by
    /// paragraph with the flowed line breaks — a reading presentation.
    /// Unflow returns to the editor; the file is untouched either way.
    /// Inline, the list scrolls, so no scroll view of its own.
    @ViewBuilder private var flowedReading: some View {
        if inline {
            flowedColumn
                .padding(.vertical, 6)
        } else {
            ScrollView {
                flowedColumn
                    .padding(.horizontal, 20)
                    .padding(.top, 33)
                    .padding(.bottom, 16)
            }
        }
    }

    private var flowedColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(LiquidDoc.parseBody(from: text)) { paragraph in
                ParagraphView(paragraph: paragraph, flowed: true)
            }
        }
        .frame(maxWidth: measure ?? .infinity, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: centersContent ? .center : .leading)
    }

    #if os(macOS)

    // MARK: Names in the writing

    /// A first or last name typed alone in the note that answers to one
    /// or more contacts.
    private struct NameMatch: Identifiable {
        let name: String
        let candidates: [Person]
        var id: String { name.lowercased() }
    }

    /// A quiet row under the writing: each detected name is clickable
    /// and reveals the full name (click to put it into the text), ＋ to
    /// start a contact from the name, and ✕ to keep it as written.
    @ViewBuilder private var nameSuggestionsBar: some View {
        let matches = nameMatches
        if !matches.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(.tertiary)
                    .help("Names in the writing that answer to your contacts")
                ForEach(matches) { match in
                    Menu {
                        ForEach(match.candidates, id: \.localID) { person in
                            Button(person.displayName) {
                                replaceName(match.name, with: person)
                            }
                        }
                        Divider()
                        Button("＋ New Person “\(match.name)”…") {
                            var person = Person()
                            person.givenName = match.name
                            newPerson = person
                        }
                        Button("✕ Keep as Written") {
                            dismissName(match.name)
                        }
                    } label: {
                        Text(match.name)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }
                    .menuIndicator(.hidden)
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("“\(match.name)” answers to a contact — click for the full name")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 6)
            .sheet(item: $newPerson) { person in
                PersonFormView(person: person, heading: "New Person") { updated in
                    state.people.upsert(updated)
                    state.publishPortraits()
                    state.index.rescan()
                }
            }
        }
    }

    /// Every capitalized word in the text that matches a contact's first
    /// or last name and stands alone — not already beside the rest of
    /// that contact's name — offered once each, dismissed ones excepted.
    private var nameMatches: [NameMatch] {
        let people = state.people.people.filter { !$0.displayName.isEmpty }
        guard !people.isEmpty, !text.isEmpty else { return [] }
        var byPart: [String: [Person]] = [:]
        for person in people {
            for part in [person.givenName, person.familyName] {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                guard trimmed.count >= 2,
                      trimmed.caseInsensitiveCompare(person.displayName) != .orderedSame
                else { continue }
                byPart[trimmed.lowercased(), default: []].append(person)
            }
        }
        guard !byPart.isEmpty else { return [] }
        var offered = Set<String>()
        var matches: [NameMatch] = []
        for range in text.ranges(of: /[A-Z][a-zA-Z'’-]*/) {
            let word = String(text[range])
            let key = word.lowercased()
            guard !offered.contains(key), !dismissedNames.contains(key),
                  let candidates = byPart[key],
                  isStandalone(range, key: key, candidates: candidates)
            else { continue }
            offered.insert(key)
            matches.append(NameMatch(name: word, candidates: candidates))
        }
        return matches
    }

    /// Whether this occurrence stands alone: its neighbours are not the
    /// adjoining parts of any candidate's full name — "Frode" inside
    /// "Frode Hegland" is already whole.
    private func isStandalone(_ range: Range<String.Index>, key: String,
                              candidates: [Person]) -> Bool {
        let before = wordBefore(range)?.lowercased()
        let after = wordAfter(range)?.lowercased()
        for person in candidates {
            let parts = person.displayName.split(separator: " ").map { $0.lowercased() }
            for (i, part) in parts.enumerated() where part == key {
                if i > 0, before == parts[i - 1] { return false }
                if i + 1 < parts.count, after == parts[i + 1] { return false }
            }
        }
        return true
    }

    /// The word just after the range, across at most a couple of
    /// non-letter characters on the same line.
    private func wordAfter(_ range: Range<String.Index>) -> String? {
        var i = range.upperBound
        var gap = 0
        while i < text.endIndex, !text[i].isLetter {
            if text[i].isNewline || gap >= 2 { return nil }
            gap += 1
            i = text.index(after: i)
        }
        guard i < text.endIndex else { return nil }
        var end = i
        while end < text.endIndex, text[end].isLetter { end = text.index(after: end) }
        return String(text[i..<end])
    }

    /// The word just before the range, under the same rules.
    private func wordBefore(_ range: Range<String.Index>) -> String? {
        var i = range.lowerBound
        var gap = 0
        while i > text.startIndex {
            let previous = text.index(before: i)
            if text[previous].isLetter { break }
            if text[previous].isNewline || gap >= 2 { return nil }
            gap += 1
            i = previous
        }
        guard i > text.startIndex, text[text.index(before: i)].isLetter else { return nil }
        var start = text.index(before: i)
        while start > text.startIndex, text[text.index(before: start)].isLetter {
            start = text.index(before: start)
        }
        return String(text[start..<i])
    }

    /// Puts the person's full name into the text wherever the single
    /// name stands alone as a whole word.
    private func replaceName(_ name: String, with person: Person) {
        var ranges: [Range<String.Index>] = []
        for range in text.ranges(of: name) {
            let wholeWord = (range.lowerBound == text.startIndex
                || !text[text.index(before: range.lowerBound)].isLetter)
                && (range.upperBound == text.endIndex || !text[range.upperBound].isLetter)
            guard wholeWord,
                  isStandalone(range, key: name.lowercased(), candidates: [person])
            else { continue }
            ranges.append(range)
        }
        for range in ranges.reversed() {
            text.replaceSubrange(range, with: person.displayName)
        }
    }

    // MARK: Dismissed names

    /// Names told to stay as written, per note — remembered, so the
    /// offer is not repeated on every visit.
    private static let dismissalsKey = "personNameDismissals"

    private func loadDismissedNames() {
        let all = UserDefaults.standard.dictionary(forKey: Self.dismissalsKey)
            as? [String: [String]] ?? [:]
        dismissedNames = Set(all[doc.id] ?? [])
    }

    private func dismissName(_ name: String) {
        dismissedNames.insert(name.lowercased())
        var all = UserDefaults.standard.dictionary(forKey: Self.dismissalsKey)
            as? [String: [String]] ?? [:]
        all[doc.id] = Array(dismissedNames).sorted()
        UserDefaults.standard.set(all, forKey: Self.dismissalsKey)
    }
    #endif

    // MARK: Backlinks

    private var backlinks: [BacklinkRef] {
        state.index.backlinks[doc.id] ?? []
    }

    @ViewBuilder private var backlinksSection: some View {
        if !backlinks.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                Text("Backlinks")
                    .font(.system(size: 15, design: .serif))
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

        // The file as it stands now is the metadata's truth: filing may
        // have cleared the draft flag, or an analysis been written in,
        // while these words were typed. Carry that metadata; only other
        // *words* arriving from elsewhere are a conflict, kept as their
        // own note before ours are written.
        let diskData = try? Data(contentsOf: doc.fileURL)
        let diskDoc = diskData.flatMap { try? LiquidDoc.decode(data: $0, fileURL: doc.fileURL) }
        let source = diskDoc ?? doc
        if let diskData, let baseDiskData, diskData != baseDiskData {
            let diskText = Self.editingText(of: source)
            if diskText != baseText, diskText != text {
                preserveConflictCopy(diskData)
            }
        }

        // Metadata blocks ride along untouched, after the words.
        let preserved = (source.body ?? []).filter { Self.hiddenIDs(of: source).contains($0.id) }
        let body = LiquidDoc.parseBody(from: text) + preserved

        // A derived title stays derived — the first four words of
        // whatever the note now says. A real title stays itself.
        let oldContent = Self.contentParagraphs(of: source).map(\.text).joined(separator: " ")
        let titleWasDerived = source.title == Self.derivedTitle(for: oldContent)
            || source.title == "Untitled"
        let title = titleWasDerived
            ? Self.derivedTitle(for: text.trimmingCharacters(in: .whitespacesAndNewlines))
            : source.title

        var updated = source
        updated.id = doc.id
        updated.title = title
        updated.body = body
        updated.links = LiquidDoc.detectedLinks(in: body)
        updated.wraps = nil
        updated.fileURL = doc.fileURL
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
            state.index.isIDTaken(candidate)
        }
        // The copy differs only in identity — a fresh id, moment, and
        // file of its own. Everything else the incoming version carried
        // (concepts, layouts, references, and fields yet to come) is
        // preserved: no part of it is lost to the race.
        var copy = incoming
        copy.id = id
        copy.title = "\(incoming.title) (conflict copy)"
        copy.created = created
        copy.wraps = nil
        copy.fileURL = folderURL.appendingPathComponent(id)
            .appendingPathExtension(LiquidDoc.fileExtension)
        try? copy.jsonData().write(to: copy.fileURL, options: .atomic)
        state.showNote("This note changed elsewhere while you wrote — the other version is kept as “\(copy.title)”.")
    }

    /// A change from elsewhere, met while this page is clean: adopt it.
    /// (With local words typed, the save path preserves both instead.)
    private func adoptExternalIfClean() {
        guard loaded, text == baseText else { return }
        // Our own save echoes back through the index rescan as a new
        // `doc` whose parsed text can differ from the buffer (saving
        // normalizes paragraph breaks). Replacing the buffer with it
        // would throw the cursor to the end mid-writing — so adopt only
        // what is genuinely from elsewhere: bytes we didn't write.
        let diskData = try? Data(contentsOf: doc.fileURL)
        guard diskData != baseDiskData else { return }
        let fresh = Self.editingText(of: doc)
        guard fresh != baseText else {
            // Metadata changed (filing, an analysis) but the words
            // stand — track the new bytes, keep the buffer.
            baseDiskData = diskData
            return
        }
        text = fresh
        baseText = fresh
        baseDiskData = diskData
    }
}
