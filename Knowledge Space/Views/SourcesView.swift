import SwiftUI
#if os(macOS)
import AppKit
#endif

// The Library section: citations as first-class citizens. A source is
// an ordinary Origami document (`documentType: "source"`) carrying its
// own BibTeX in `references`; quotes and annotations are documents of
// their own, connected to the source by links. The reference manager
// is a view over the folder — no second system, no database.

// MARK: - BibTeX records

/// A BibTeX entry, parsed just enough to shelve it: entry type, key,
/// and the display fields. The verbatim text remains the record —
/// parsing is presentation, never storage.
nonisolated struct BibTeXRecord: Sendable {
    let raw: String
    let entryType: String
    let key: String
    let fields: [String: String]

    var author: String { fields["author"] ?? fields["editor"] ?? "" }
    var title: String { fields["title"] ?? "" }
    var year: String { fields["year"] ?? "" }

    /// True for the book-shaped entry types.
    var isBook: Bool { entryType.localizedCaseInsensitiveContains("book") }

    /// The Books shelf's rule: a book as the record says (the user's
    /// assignment rewrites the entry type), or a work with an ISBN and
    /// no DOI. Everything else — DOI-bearing papers, Reader's PDFs —
    /// shelves under Articles.
    var shelvesAsBook: Bool {
        if isBook { return true }
        return fields["isbn"] != nil && fields["doi"] == nil
    }

    /// Authors as "First Last, First Last" for display; BibTeX's
    /// "Last, First" and "First Last" forms both read correctly.
    var displayAuthors: String {
        author.components(separatedBy: " and ")
            .map { name -> String in
                let parts = name.components(separatedBy: ",")
                guard parts.count == 2 else {
                    return name.trimmingCharacters(in: .whitespaces)
                }
                let last = parts[0].trimmingCharacters(in: .whitespaces)
                let first = parts[1].trimmingCharacters(in: .whitespaces)
                return first.isEmpty ? last : "\(first) \(last)"
            }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    /// The individual author names, for the Authors shelf.
    var individualAuthors: [String] {
        displayAuthors.components(separatedBy: ", ").filter { !$0.isEmpty }
    }

    /// The §4 citation sentence for this record (without an address).
    var citationSentence: String {
        var sentence = "“\(title.isEmpty ? "Untitled" : title)”"
        let credit = [displayAuthors, year].filter { !$0.isEmpty }.joined(separator: ", ")
        if !credit.isEmpty { sentence += " (\(credit))" }
        return sentence
    }

    /// Every entry found in a pasted text — tolerant: what does not
    /// parse is skipped, per the format's reading rules.
    static func records(in text: String) -> [BibTeXRecord] {
        var records: [BibTeXRecord] = []
        var search = text.startIndex
        while let at = text[search...].firstIndex(of: "@") {
            guard let open = text[at...].firstIndex(of: "{") else { break }
            var depth = 0
            var index = open
            var end: String.Index?
            while index < text.endIndex {
                if text[index] == "{" { depth += 1 }
                if text[index] == "}" {
                    depth -= 1
                    if depth == 0 { end = index; break }
                }
                index = text.index(after: index)
            }
            guard let end else { break }
            if let record = parse(String(text[at...end])) {
                records.append(record)
            }
            search = text.index(after: end)
        }
        return records
    }

    /// One entry, "@type{key, name = {value}, …}". Nil for the
    /// non-record kinds (@comment, @string, @preamble) and anything
    /// that does not scan.
    static func parse(_ entry: String) -> BibTeXRecord? {
        guard entry.hasPrefix("@"),
              let open = entry.firstIndex(of: "{") else { return nil }
        let entryType = entry[entry.index(after: entry.startIndex)..<open]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !["comment", "string", "preamble"].contains(entryType.lowercased())
        else { return nil }

        let inner = String(entry[entry.index(after: open)..<entry.index(before: entry.endIndex)])
        guard let comma = inner.firstIndex(of: ",") else { return nil }
        let key = inner[..<comma].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }

        var fields: [String: String] = [:]
        var rest = Substring(inner[inner.index(after: comma)...])
        while let equals = rest.firstIndex(of: "=") {
            let name = rest[..<equals]
                .trimmingCharacters(in: CharacterSet(charactersIn: ", \n\t\r"))
                .lowercased()
            var valueStart = rest.index(after: equals)
            while valueStart < rest.endIndex, rest[valueStart].isWhitespace {
                valueStart = rest.index(after: valueStart)
            }
            guard valueStart < rest.endIndex else { break }
            var value = ""
            var next = valueStart
            switch rest[valueStart] {
            case "{":
                var depth = 0
                var index = valueStart
                while index < rest.endIndex {
                    if rest[index] == "{" { depth += 1 }
                    if rest[index] == "}" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    index = rest.index(after: index)
                }
                guard index < rest.endIndex else { return fields.isEmpty ? nil : made(entry, entryType, key, fields) }
                value = String(rest[rest.index(after: valueStart)..<index])
                next = rest.index(after: index)
            case "\"":
                var index = rest.index(after: valueStart)
                while index < rest.endIndex, rest[index] != "\"" {
                    index = rest.index(after: index)
                }
                guard index < rest.endIndex else { return fields.isEmpty ? nil : made(entry, entryType, key, fields) }
                value = String(rest[rest.index(after: valueStart)..<index])
                next = rest.index(after: index)
            default:
                var index = valueStart
                while index < rest.endIndex, rest[index] != "," {
                    index = rest.index(after: index)
                }
                value = rest[valueStart..<index].trimmingCharacters(in: .whitespacesAndNewlines)
                next = index
            }
            if !name.isEmpty {
                fields[name] = value
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "{", with: "")
                    .replacingOccurrences(of: "}", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
            guard next < rest.endIndex else { break }
            rest = rest[rest.index(after: next)...]
        }
        return made(entry, entryType, key, fields)
    }

    private static func made(_ raw: String, _ type: String, _ key: String,
                             _ fields: [String: String]) -> BibTeXRecord {
        BibTeXRecord(raw: raw, entryType: type, key: key, fields: fields)
    }
}

// MARK: - Minting sources, quotes, and annotations

extension AppState {

    /// Every source document on the shelf.
    var sourceEntries: [IndexEntry] {
        index.byID.values.filter {
            $0.doc.documentType == LiquidDoc.DocumentType.source.rawValue
        }
        .sorted { $0.doc.title.localizedCaseInsensitiveCompare($1.doc.title) == .orderedAscending }
    }

    /// The source already shelved for a BibTeX key, if any — one
    /// source, one address; import never duplicates.
    func existingSource(forKey key: String) -> LiquidDoc? {
        sourceEntries.first {
            $0.doc.references.first?.id.caseInsensitiveCompare(key) == .orderedSame
        }?.doc
    }

    /// Mints a source document from one BibTeX record: the citation
    /// sentence as its readable body, the verbatim record as its
    /// authoritative reference, the work's year as its date.
    @discardableResult
    func createSource(from record: BibTeXRecord) -> LiquidDoc? {
        guard let folderURL = index.folderURL else {
            showNote("Choose a library folder first — sources live there.")
            return nil
        }
        if let existing = existingSource(forKey: record.key) {
            showNote("“\(existing.title)” is already on the shelf.")
            return existing
        }
        let created = Date.now
        let id = LiquidAddress.makeID(author: authorName, created: created) {
            self.index.isIDTaken($0)
        }
        var doc = LiquidDoc(format: LiquidDoc.knownFormat,
                            id: id,
                            title: record.title.isEmpty ? "Untitled Source" : record.title,
                            author: authorName,
                            created: created,
                            body: [LiquidDoc.Paragraph(id: "p1", heading: nil,
                                                       text: record.citationSentence + " [\(id)]")],
                            links: [],
                            wraps: nil,
                            fileURL: folderURL.appendingPathComponent(id)
                                .appendingPathExtension(LiquidDoc.fileExtension))
        doc.documentType = LiquidDoc.DocumentType.source.rawValue
        doc.references = [LiquidDoc.Reference(id: record.key, bibtex: record.raw)]
        if !record.year.isEmpty {
            doc.date = LiquidDate(isoString: record.year)
        }
        do {
            try doc.jsonData().write(to: doc.fileURL, options: .atomic)
            index.rescan()
            return doc
        } catch {
            showNote("Could not write the source: \(error.localizedDescription)")
            return nil
        }
    }

    /// A dropped file becomes a sidecar source: the file copies into
    /// the community folder and a wrapper document gives it an address
    /// (§8) — hash recorded, identity-key address honored when the
    /// name carries one.
    @discardableResult
    func createSource(wrapping fileURL: URL) -> LiquidDoc? {
        guard let folderURL = index.folderURL else {
            showNote("Choose a library folder first — sources live there.")
            return nil
        }
        let destination = folderURL.appendingPathComponent(fileURL.lastPathComponent)
        if !FileManager.default.fileExists(atPath: destination.path) {
            do {
                try FileManager.default.copyItem(at: fileURL, to: destination)
            } catch {
                showNote("Could not copy the file into the folder: \(error.localizedDescription)")
                return nil
            }
        }
        let created = Date.now
        // A Visual-Meta ecosystem file name carries the work's own
        // deterministic address; otherwise the record mints one.
        let derived = LiquidDoc.identityKeyID(inFileName: fileURL.lastPathComponent)
        let id = derived.flatMap { index.isIDTaken($0) ? nil : $0 }
            ?? LiquidAddress.makeID(author: authorName, created: created) {
                self.index.isIDTaken($0)
            }
        var doc = LiquidDoc(format: LiquidDoc.knownFormat,
                            id: id,
                            title: fileURL.deletingPathExtension().lastPathComponent,
                            author: authorName,
                            created: created,
                            body: nil,
                            links: [],
                            wraps: LiquidDoc.Wrapped(
                                file: fileURL.lastPathComponent,
                                sha256: FileHasher.sha256Hex(of: destination) ?? "",
                                mediaType: fileURL.pathExtension.lowercased() == "pdf"
                                    ? "application/pdf" : nil),
                            fileURL: folderURL.appendingPathComponent(id)
                                .appendingPathExtension(LiquidDoc.fileExtension))
        doc.documentType = LiquidDoc.DocumentType.source.rawValue
        do {
            try doc.jsonData().write(to: doc.fileURL, options: .atomic)
            index.rescan()
            return doc
        } catch {
            showNote("Could not write the source: \(error.localizedDescription)")
            return nil
        }
    }

    /// A quote: the source's words in a document of their own. The
    /// `cites` link carries the words again as its span, with the
    /// locator naming where in the work. Settled at birth — a quote
    /// belongs to its source, not the Inbox.
    @discardableResult
    func createQuote(_ words: String, locator: String?, on source: LiquidDoc) -> LiquidDoc? {
        createConnected(kind: .quote, body: words,
                        link: LiquidDoc.Link(to: source.id, fragment: nil, rel: "cites",
                                             bibtex: source.references.first?.bibtex,
                                             span: words,
                                             locator: locator))
    }

    /// An annotation: a comment anchored to a place in the source.
    @discardableResult
    func createAnnotation(_ comment: String, locator: String?, on source: LiquidDoc) -> LiquidDoc? {
        createConnected(kind: .annotation, body: comment,
                        link: LiquidDoc.Link(to: source.id, fragment: nil, rel: "annotates",
                                             locator: locator))
    }

    /// An ordinary note that stands on the source — it lives the note's
    /// life (Inbox, drafts, actions), connected by its link.
    @discardableResult
    func createSourceNote(on source: LiquidDoc) -> LiquidDoc? {
        let doc = createConnected(kind: .note, body: "",
                                  link: LiquidDoc.Link(to: source.id, fragment: nil,
                                                       rel: "relates-to"),
                                  asDraft: true)
        if let doc { selectedDocID = doc.id }
        return doc
    }

    private func createConnected(kind: LiquidDoc.DocumentType, body: String,
                                 link: LiquidDoc.Link, asDraft: Bool = false) -> LiquidDoc? {
        guard let folderURL = index.folderURL else {
            showNote("Choose a library folder first.")
            return nil
        }
        let created = Date.now
        let id = LiquidAddress.makeID(author: authorName, created: created) {
            self.index.isIDTaken($0)
        }
        let paragraphs = LiquidDoc.parseBody(from: body)
        let title = body.split(whereSeparator: \.isWhitespace).prefix(4).joined(separator: " ")
        var doc = LiquidDoc(format: LiquidDoc.knownFormat,
                            id: id,
                            title: title.isEmpty ? "Untitled" : title,
                            author: authorName,
                            created: created,
                            body: paragraphs,
                            links: [link],
                            wraps: nil,
                            draft: asDraft,
                            fileURL: folderURL.appendingPathComponent(id)
                                .appendingPathExtension(LiquidDoc.fileExtension))
        doc.documentType = kind.rawValue
        do {
            try doc.jsonData().write(to: doc.fileURL, options: .atomic)
            index.rescan()
            return doc
        } catch {
            showNote("Could not write it: \(error.localizedDescription)")
            return nil
        }
    }

    /// The user's word on a source's kind: the record's entry type is
    /// rewritten (@book / @article) — the shelves read it, so the
    /// citation record says what the user says the work is.
    func setSourceKind(book: Bool, for doc: LiquidDoc) {
        guard var reference = doc.references.first,
              reference.bibtex.hasPrefix("@"),
              let brace = reference.bibtex.firstIndex(of: "{") else { return }
        reference.bibtex = "@\(book ? "book" : "article")"
            + reference.bibtex[brace...]
        var updated = doc
        updated.references[0] = reference
        do {
            try updated.jsonData().write(to: updated.fileURL, options: .atomic)
            index.rescan()
        } catch {
            showNote("Could not reshelve the source: \(error.localizedDescription)")
        }
    }

    /// The §4 citation sentence with the source's live address, onto
    /// the pasteboard — paste it into any note and the address becomes
    /// a structured link on save.
    func copyCitation(for source: LiquidDoc) {
        let record = source.references.first.flatMap { BibTeXRecord.parse($0.bibtex) }
        let sentence = (record?.citationSentence ?? "“\(source.title)”") + " [\(source.id)]"
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sentence, forType: .string)
        #endif
        showNote("Citation copied — paste it into any note.")
    }
}

// MARK: - The shelves

/// The Library section's places: the whole shelf, its kinds, the
/// cited authors, and the quotes.
struct SourcesView: View {
    @Environment(AppState.self) private var state
    let shelf: SourceShelf

    @State private var selectedSourceID: String?
    @State private var addingBibTeX = false
    @State private var search = ""
    /// A cited author on their way into the contacts, via ctrl-click.
    @State private var newPerson: Person?

    /// The Authors shelf's open author — held by the app, not the
    /// view, so Show in Authors lands selected regardless of whether
    /// this view was rebuilt or merely handed a different shelf.
    private var selectedAuthor: String? {
        get { state.selectedShelfAuthor }
        nonmutating set { state.selectedShelfAuthor = newValue }
    }

    private struct ShelfEntry: Identifiable {
        let doc: LiquidDoc
        let record: BibTeXRecord?
        var id: String { doc.id }
        var authors: String { record?.displayAuthors ?? "" }
        var year: String { record?.year ?? "" }
        /// The work's title as the record has it — the record knows the
        /// work; the document title may be only a file's name.
        var displayTitle: String {
            if let title = record?.title, !title.isEmpty { return title }
            return doc.title
        }
    }

    private var allEntries: [ShelfEntry] {
        state.sourceEntries.map {
            ShelfEntry(doc: $0.doc,
                       record: $0.doc.references.first.flatMap { BibTeXRecord.parse($0.bibtex) })
        }
    }

    private var shelfEntries: [ShelfEntry] {
        var entries = allEntries
        switch shelf {
        case .books: entries = entries.filter { $0.record?.shelvesAsBook == true }
        case .articles: entries = entries.filter { $0.record?.shelvesAsBook != true }
        case .authors:
            if let selectedAuthor {
                // By ear, not by letter: the name may arrive in a
                // transcript's or a menu's spelling.
                entries = entries.filter {
                    $0.record?.individualAuthors.contains {
                        $0.caseInsensitiveCompare(selectedAuthor) == .orderedSame
                    } == true
                }
            }
        case .all, .quotes: break
        }
        guard !search.isEmpty else { return entries }
        return entries.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(search)
                || $0.authors.localizedCaseInsensitiveContains(search)
                || $0.year.localizedCaseInsensitiveContains(search)
        }
    }

    /// A source's title as its record has it, wherever the shelf shows
    /// one — the stored title may be only a file's name.
    static func displayTitle(of doc: LiquidDoc) -> String {
        if let bibtex = doc.references.first?.bibtex,
           let title = BibTeXRecord.parse(bibtex)?.title, !title.isEmpty {
            return title
        }
        return doc.title
    }

    /// Every cited author, with how many works of theirs are shelved.
    private var citedAuthors: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for entry in allEntries {
            for name in entry.record?.individualAuthors ?? [] {
                counts[name, default: 0] += 1
            }
        }
        return counts.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { (name: $0.key, count: $0.value) }
    }

    /// Every quote on the shelf, with the source it stands on.
    private var quoteEntries: [(quote: LiquidDoc, source: LiquidDoc?)] {
        state.index.byID.values
            .filter { $0.doc.documentType == LiquidDoc.DocumentType.quote.rawValue }
            .map { entry in
                let sourceID = entry.doc.links.first?.to
                return (entry.doc, sourceID.flatMap { state.index.byID[$0]?.doc })
            }
            .sorted { $0.quote.created > $1.quote.created }
    }

    var body: some View {
        Group {
            if shelfIsEmpty {
                // An empty shelf offers no blank column — the
                // invitation takes the room.
                emptyShelf
            } else {
                HStack(spacing: 0) {
                    shelfColumn
                        .frame(width: 300)
                    Divider()
                    if let entry = shelfEntries.first(where: { $0.doc.id == selectedSourceID })
                        ?? allEntries.first(where: { $0.doc.id == selectedSourceID }) {
                        SourcePageView(doc: entry.doc, record: entry.record)
                    } else {
                        // Hand-rolled, deliberately: ContentUnavailableView
                        // shoves its whole container sideways inside a
                        // split-view detail — the white-column bug.
                        placeholder("The Shelf",
                                    message: "Choose a work from the list — or add more by pasting BibTeX or dropping a PDF.")
                    }
                }
            }
        }
        .sheet(isPresented: $addingBibTeX) {
            AddBibTeXSheet()
        }
        .greyColumnAppearance()
    }

    /// The Analyze New button wears its own progress while it works.
    private var analyzeButtonLabel: String {
        if let progress = state.sourceAnalysisProgress {
            return "Analyzing \(progress.done) of \(progress.total)…"
        }
        return "Analyze New"
    }

    /// Re-scan's too.
    private var rescanButtonLabel: String {
        if let progress = state.readerRescanProgress {
            return "Re-scanning \(progress.done) of \(progress.total)…"
        }
        return "Re-scan"
    }

    /// Whether the current shelf has anything to list yet.
    private var shelfIsEmpty: Bool {
        switch shelf {
        case .authors: citedAuthors.isEmpty
        case .quotes: quoteEntries.isEmpty
        default: allEntries.isEmpty
        }
    }

    private var emptyShelf: some View {
        VStack(spacing: 12) {
            placeholder("The Shelf",
                        message: "Sources are documents like everything else: one file per work, its BibTeX aboard, quotes and annotations standing on it. Add works by pasting BibTeX, or drop a PDF or EPUB here — an Origami EPUB arrives whole, text, glossary, and images — and the Reader Library, once granted in Settings ▸ Library, fills the shelf from its Visual-Meta PDFs.")
                .frame(maxHeight: 280, alignment: .bottom)
            Button("Add Sources (BibTeX)…") { addingBibTeX = true }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
        }
    }

    /// The quiet empty-state, hand-rolled: the system's
    /// ContentUnavailableView disturbs split-view detail layout on
    /// macOS (the white-column bug), so the shelf draws its own.
    private func placeholder(_ title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "books.vertical")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A dropped file becomes a sidecar source, wherever it lands — an
    /// EPUB is read whole instead: its text, glossary, references, and
    /// images minted as a full document, the EPUB kept beside it.
    private func handleDrop(_ urls: [URL]) -> Bool {
        var added = false
        for url in urls where url.isFileURL {
            if url.pathExtension.lowercased() == "epub" {
                // Read whole, off the main actor; the shelf refreshes
                // when the book lands.
                state.importOrigamiEPUB(from: url)
                added = true
            } else if let doc = state.createSource(wrapping: url) {
                selectedSourceID = doc.id
                added = true
            }
        }
        return added
    }

    @ViewBuilder private var shelfColumn: some View {
        VStack(spacing: 0) {
            switch shelf {
            case .authors where selectedAuthor == nil:
                authorList
            case .quotes:
                quoteList
            default:
                sourceList
            }
            Divider()
            HStack {
                Button("Add Sources…") { addingBibTeX = true }
                    .help("Paste BibTeX — every entry becomes a source document. A PDF or EPUB can simply be dropped on the list; an Origami EPUB arrives whole.")
                Button(analyzeButtonLabel) {
                    state.analyzeNewSources()
                }
                .disabled(state.sourceAnalysisRunning)
                .help("Summary, keywords, names mentioned, and concepts for sources not yet studied, read from their PDFs by Apple Intelligence's on-device model — nothing leaves the machine")
                Button(rescanButtonLabel) {
                    state.reharvestSources()
                }
                .disabled(state.readerScanRunning || state.readerLibraryURL == nil)
                .help("Re-reads every shelved source's PDF Visual-Meta, refreshing titles, authors, abstracts, and margin notes the first scans may have missed — your own edits and shelving stay")
                Spacer()
            }
            .padding(10)
        }
    }

    private var sourceList: some View {
        VStack(spacing: 0) {
            if shelf == .authors, let selectedAuthor {
                HStack {
                    Button {
                        self.selectedAuthor = nil
                    } label: {
                        Label(selectedAuthor, systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(8)
            }
            // A plain SwiftUI list, deliberately: the AppKit-backed
            // List mislays its first layout inside a fixed-width
            // column, standing as a white stripe until a click.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(shelfEntries) { entry in
                        shelfRow(entry)
                    }
                }
                .padding(8)
            }
            .searchable(text: $search, placement: .automatic, prompt: "Title, author, or year")
            .dropDestination(for: URL.self) { urls, _ in
                handleDrop(urls)
            }
        }
    }

    /// One work on the shelf, selection drawn by hand.
    private func shelfRow(_ entry: ShelfEntry) -> some View {
        Button {
            selectedSourceID = entry.doc.id
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                // The full title, however long — a shelf names its
                // works whole, by their records.
                Text(entry.displayTitle)
                    .fontWeight(.medium)
                HStack(spacing: 6) {
                    Text([entry.authors, entry.year]
                        .filter { !$0.isEmpty }
                        .joined(separator: " · "))
                    if entry.doc.wraps != nil {
                        Image(systemName: "paperclip")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selectedSourceID == entry.doc.id
                        ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 6))
        #if os(macOS)
        // A work whose first scan came up short — a file name standing
        // for the title, say — is re-read from its PDF on ctrl-click.
        .contextMenu {
            Button("Re-Process") {
                state.reprocessSource(entry.doc)
            }
            .disabled(state.readerScanRunning)
        }
        #endif
    }

    private var authorList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(citedAuthors, id: \.name) { author in
                    Button {
                        selectedAuthor = author.name
                    } label: {
                        HStack {
                            Text(author.name)
                            Spacer()
                            Text("\(author.count)")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    #if os(macOS)
                    // A cited author may be — or become — a person of
                    // the community: ctrl-click starts their record.
                    .contextMenu {
                        if state.people.person(named: author.name) == nil {
                            Button("Add “\(author.name)” to Contacts…") {
                                newPerson = Person(displayName: author.name)
                            }
                        } else {
                            Button("Already in Contacts") {}
                                .disabled(true)
                        }
                    }
                    #endif
                }
            }
            .padding(8)
        }
        #if os(macOS)
        .sheet(item: $newPerson) { person in
            PersonFormView(person: person, heading: "New Person") { updated in
                state.people.upsert(updated)
                state.publishPortraits()
                state.index.rescan()
            }
        }
        #endif
    }

    private var quoteList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(quoteEntries, id: \.quote.id) { entry in
                    Button {
                        // A quote answers with its source's page.
                        selectedSourceID = entry.source?.id ?? entry.quote.id
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("“\(entry.quote.title)…”")
                                .lineLimit(2)
                            if let source = entry.source {
                                Text(SourcesView.displayTitle(of: source))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(selectedSourceID == (entry.source?.id ?? entry.quote.id)
                                    ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                                in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(8)
        }
    }
}

// MARK: - The source page

/// One source: its citation, its record, the work when wrapped, and
/// everything standing on it — quotes, annotations, notes — each a
/// document of its own, gathered by backlinks. Internal, not private:
/// the EPUB shelf shows the same page for its works.
struct SourcePageView: View {
    @Environment(AppState.self) private var state
    let doc: LiquidDoc
    let record: BibTeXRecord?
    /// Where Read leads: a context that can read in place (the EPUB
    /// shelf) hands its own door; nil opens in the library.
    var readAction: (() -> Void)? = nil

    @State private var quoting = false
    @State private var annotating = false
    @State private var showsRecord = false
    /// A mentioned name on its way into the contacts.
    @State private var newPerson: Person?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(SourcesView.displayTitle(of: doc))
                    .font(.system(size: 26, weight: .bold, design: .serif))
                HStack(spacing: 6) {
                    if let record {
                        if !record.displayAuthors.isEmpty { Text(record.displayAuthors) }
                        if !record.year.isEmpty { Text("· \(record.year)") }
                        Text("· \(record.entryType.lowercased())")
                    }
                }
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button("Copy to Cite") { state.copyCitation(for: doc) }
                        .help("The citation sentence with this source's address — paste it into any note and the address becomes a live link on save")
                    // A work whose text is aboard — an imported EPUB —
                    // reads whole in the reader, not on this card.
                    if (doc.body?.count ?? 0) > 4 {
                        Button("Read") {
                            if let readAction {
                                readAction()
                            } else {
                                state.openInLibrary(doc)
                            }
                        }
                        .help("The whole work in the reader — its text is aboard the document itself")
                    }
                    if let wraps = doc.wraps {
                        Button("Open \(wraps.file)") { openWrapped(wraps) }
                    }
                    #if os(macOS)
                    if let epub = state.epubCompanionURL(for: doc) {
                        Button("Show EPUB") {
                            NSWorkspace.shared.activateFileViewerSelecting([epub])
                        }
                        .help("The EPUB this document arrived from — in the EPUB Library, or beside the document where no EPUB Library is chosen")
                    }
                    if doc.body != nil {
                        Button("Export EPUB…") { state.exportOrigamiEPUB(doc) }
                            .help("Writes the document as an Origami-profile EPUB — a valid EPUB anywhere, whole to any Origami reader")
                    }
                    #endif
                    if let pdf = pdfPointer {
                        Button("Open PDF") {
                            state.openSourcePDF(named: pdf.name, recordedFolder: pdf.folder)
                        }
                        .help("Opens “\(pdf.name)” in the Mac's PDF app — Reader, where Reader owns PDFs")
                    }
                    Button("Quote…") { quoting = true }
                    Button("Annotate…") { annotating = true }
                    Button("New Note") { _ = state.createSourceNote(on: doc) }
                        .help("An ordinary note standing on this source — it lives the note's life, connected by its link")
                    // A work with sections offers each as an excerpt: the
                    // section carved out as a document of its own, its
                    // citations still addressing the original.
                    let headings = (doc.body ?? []).filter { $0.heading != nil }
                    if !headings.isEmpty {
                        Menu("Excerpt") {
                            ForEach(headings) { heading in
                                Button(heading.displayText) {
                                    state.excerptSection(of: doc, headingID: heading.id)
                                }
                            }
                        }
                        .menuStyle(.button)
                        .fixedSize()
                        .help("Carve a section out as a document of its own — paragraph ids kept, so citations from the excerpt address the original")
                    }
                }
                .buttonStyle(GreyColumnButtonStyle())
                .fixedSize()

                if let record {
                    // The user's word beats the record's guess: reshelve
                    // a work between Books and Articles at a click.
                    Button(record.shelvesAsBook
                           ? "Shelve as \(state.articlesShelfLabel == "Papers" ? "Paper" : "Article")"
                           : "Shelve as Book") {
                        state.setSourceKind(book: !record.shelvesAsBook, for: doc)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("Books are what you say are books — or works with an ISBN and no DOI; everything else shelves with the articles")

                    DisclosureGroup("BibTeX record", isExpanded: $showsRecord) {
                        Text(record.raw)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                }

                // The source's own page: abstract, summary — whatever
                // its body carries beyond the citation, the PDF
                // pointer, and the term lines (the chips below carry
                // those more usefully).
                let bodyLines = (doc.body ?? []).dropFirst().filter { paragraph in
                    !paragraph.text.hasPrefix("PDF: ")
                        && !(hasTermChips && (paragraph.text.hasPrefix("Keywords: ")
                            || paragraph.text.hasPrefix("Names mentioned: ")
                            || paragraph.text.hasPrefix("Concepts: ")))
                }
                if !bodyLines.isEmpty {
                    Divider()
                    // The card shows a work's opening; a whole book
                    // reads in the reader, where Read leads.
                    ForEach(Array(bodyLines.prefix(60))) { paragraph in
                        ParagraphView(paragraph: paragraph, origami: doc)
                    }
                    if bodyLines.count > 60 {
                        Text("The card shows the opening — Read opens the whole work.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                if hasTermChips {
                    Divider()
                    termChips
                }

                connectedSection("Quotes", kind: LiquidDoc.DocumentType.quote.rawValue,
                                 icon: "quote.opening")
                connectedSection("Annotations", kind: LiquidDoc.DocumentType.annotation.rawValue,
                                 icon: "text.bubble")
                connectedSection("Notes and citations", kind: nil, icon: "note.text")
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppGreys.page)
        .sheet(isPresented: $quoting) {
            ConnectedTextSheet(heading: "Quote from “\(doc.title)”",
                               prompt: "The words, exactly as the source has them.",
                               action: "Keep the Quote") { words, locator in
                _ = state.createQuote(words, locator: locator, on: doc)
            }
        }
        .sheet(isPresented: $annotating) {
            ConnectedTextSheet(heading: "Annotate “\(doc.title)”",
                               prompt: "Your comment on a place in the work.",
                               action: "Keep the Annotation") { comment, locator in
                _ = state.createAnnotation(comment, locator: locator, on: doc)
            }
        }
        #if os(macOS)
        .sheet(item: $newPerson) { person in
            PersonFormView(person: person, heading: "New Person") { updated in
                state.people.upsert(updated)
                state.publishPortraits()
                state.index.rescan()
            }
        }
        #endif
    }

    /// The documents standing on this source, one kind at a time; the
    /// catch-all row (kind nil) shows everything else that cites it.
    @ViewBuilder
    private func connectedSection(_ title: String, kind: String?, icon: String) -> some View {
        let connected = (state.index.backlinks[doc.id] ?? [])
            .compactMap { state.index.allByID[$0.fromID]?.doc }
            .filter { kind == nil ? !$0.isLibraryKind : $0.documentType == kind }
        if !connected.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                Label(title, systemImage: icon)
                    .font(.system(size: 15, design: .serif))
                    .foregroundStyle(.secondary)
                ForEach(connected) { item in
                    Button {
                        state.openInLibrary(item)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(itemPreview(item))
                                .lineLimit(2)
                            if let locator = item.links.first(where: { $0.to == doc.id })?.locator {
                                Text(locator)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var hasTermChips: Bool { !doc.concepts.isEmpty }

    /// The study's terms as live buttons: keywords, concepts, and the
    /// names mentioned (tagged person in the concept pool). Each opens
    /// any view narrowed to the term; a name can also stand in the
    /// Authors shelf or begin a contact record.
    private var termChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Keywords, names, and concepts", systemImage: "tag")
                .font(.system(size: 15, design: .serif))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)],
                      alignment: .leading, spacing: 6) {
                ForEach(doc.concepts) { concept in
                    termChip(concept)
                }
            }
        }
    }

    private func termChip(_ concept: LiquidDoc.Concept) -> some View {
        let isName = concept.tag == "person"
        return Menu {
            Menu("Show in") {
                ForEach(LibraryViewRegistry.modules) { module in
                    Button(module.name) {
                        state.showTerm(concept.name, inView: module.id, from: doc.id)
                    }
                }
            }
            if isName {
                Divider()
                Button("Show in People") { state.showPerson(concept.name) }
                Button("Show in Authors") { state.showCitedAuthor(concept.name) }
                #if os(macOS)
                if state.people.person(named: concept.name) == nil {
                    Button("Add to Contacts…") {
                        newPerson = Person(displayName: concept.name)
                    }
                }
                #endif
            }
        } label: {
            HStack(spacing: 4) {
                if isName {
                    Image(systemName: "person")
                }
                Text(concept.name)
                    .lineLimit(1)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .help(isName
              ? "A name the work mentions — open it in any view, stand it in Authors, or start a contact"
              : "Open any view narrowed to “\(concept.name)”")
    }

    /// The source's pointer to its PDF, read from the body's "PDF:"
    /// line — the name every machine shares, the folder the importing
    /// Mac recorded.
    private var pdfPointer: (name: String, folder: String?)? {
        guard let line = (doc.body ?? []).first(where: { $0.text.hasPrefix("PDF: ") })?.text
        else { return nil }
        let rest = line.dropFirst("PDF: ".count)
        guard let separator = rest.range(of: " — kept in ") else {
            let name = rest.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : (name, nil)
        }
        let name = String(rest[..<separator.lowerBound])
        var folder = String(rest[separator.upperBound...])
        if let suffix = folder.range(of: " on the importing Mac") {
            folder = String(folder[..<suffix.lowerBound])
        }
        return (name, folder.isEmpty ? nil : folder)
    }

    private func itemPreview(_ item: LiquidDoc) -> String {
        let words = (item.body ?? [])
            .filter { !item.visualMetaParagraphIDs.contains($0.id) }
            .map(\.displayText)
            .joined(separator: " ")
        return words.isEmpty ? item.title : words
    }

    private func openWrapped(_ wraps: LiquidDoc.Wrapped) {
        #if os(macOS)
        let url = doc.fileURL.deletingLastPathComponent()
            .appendingPathComponent(wraps.file)
        NSWorkspace.shared.open(url)
        #endif
    }
}

// MARK: - Adding sources

/// Paste BibTeX; every entry becomes a source document on the shelf.
private struct AddBibTeXSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private var found: [BibTeXRecord] { BibTeXRecord.records(in: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Sources")
                .font(.title3)
            Text("Paste BibTeX — from a reference manager, a publisher's page, or a paper's own record. Every entry becomes a source document in the community folder, its record aboard, ready to be cited, quoted, and annotated.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 220)
            HStack {
                Text(found.isEmpty ? "No entries yet." :
                        (found.count == 1 ? "1 entry found." : "\(found.count) entries found."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add to Shelf") {
                    for record in found {
                        _ = state.createSource(from: record)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(found.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 560, height: 400)
    }
}

#Preview("Sources shelf") {
    SourcesView(shelf: .all)
        .environment(AppState())
        .frame(width: 900, height: 560)
}

#Preview("Library window") {
    NavigationSplitView(columnVisibility: .constant(.doubleColumn)) {
        LibrarySidebarView()
            #if os(macOS)
            .toolbar(removing: .sidebarToggle)
            #endif
    } detail: {
        SourcesView(shelf: .all)
            .environment(\.colorScheme, .light)
    }
    .environment(AppState())
    .frame(width: 1000, height: 600)
}

/// The shared shape of the Quote and Annotate sheets: the words, a
/// locator, one button.
private struct ConnectedTextSheet: View {
    @Environment(\.dismiss) private var dismiss
    let heading: String
    let prompt: String
    let action: String
    let onKeep: (String, String?) -> Void

    @State private var text = ""
    @State private var locator = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(heading)
                .font(.title3)
                .lineLimit(1)
            Text(prompt)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(size: 14, design: .serif))
                .frame(minHeight: 140)
            TextField("Where in the work — p. 37, chapter 3, 12:40 (optional)", text: $locator)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(action) {
                    let trimmedLocator = locator.trimmingCharacters(in: .whitespaces)
                    onKeep(text.trimmingCharacters(in: .whitespacesAndNewlines),
                           trimmedLocator.isEmpty ? nil : trimmedLocator)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 520, height: 340)
    }
}
