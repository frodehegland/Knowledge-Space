#if os(macOS)
import SwiftUI
import AppKit
import PDFKit

// The file libraries: the works as files, each offered three ways —
// Alphabetical (every title A–Z), Authors (the writers, their works
// under them), and Journals (the journal or proceedings each record's
// BibTeX names). PDF lists the Reader Library folder as it stands on
// disk — the PDFs open into Reader, never moved. EPUB lists the EPUB
// Library — works imported whole read right here.

extension AppState {
    /// Author's booklet, from any work the app holds: an EPUB is
    /// paginated onto A4 pages first, a PDF imposed as it stands; the
    /// print panel comes up preset — landscape, double-sided,
    /// short-edge flip — fold the printed stack in half and it reads
    /// as a book. Offered on the file shelves' context menus and as
    /// File ▸ Print Booklet… over the front reading. (The imposition
    /// lives in BookletImposer.swift/EPUBBookletRenderer.swift,
    /// verbatim from Author — fix there, re-copy.)
    func printBooklet(from url: URL) {
        let title = url.deletingPathExtension().lastPathComponent
        let source: PDFDocument? = url.pathExtension.lowercased() == "epub"
            ? EPUBBookletRenderer.pdfDocument(fromEPUBAt: url)
            : PDFDocument(url: url)
        guard let source,
              let booklet = BookletImposer.imposed(from: source, footerTitle: title) else {
            showNote("\(title) could not be laid out as booklet pages.")
            return
        }
        BookletImposer.runPrintOperation(for: booklet, jobTitle: title,
                                         window: NSApp.keyWindow)
    }
}

/// The journal or proceedings a record says its work appeared in —
/// the record's own venue rule (BibTeXRecord.venue), where a book
/// naming no journal answers with its publisher.
private func venue(of record: BibTeXRecord?) -> String? {
    record?.venue
}

/// One group on a shelf — an author or a journal — with its count.
private struct ShelfGroup: Identifiable {
    let name: String
    let count: Int
    var id: String { name.lowercased() }
}

/// Names gathered case-insensitively, alphabetical, first spelling kept.
private func gatherGroups(_ names: [String]) -> [ShelfGroup] {
    var counts: [String: (name: String, count: Int)] = [:]
    for name in names {
        let key = name.lowercased()
        counts[key] = (counts[key]?.name ?? name, (counts[key]?.count ?? 0) + 1)
    }
    return counts.values
        .map { ShelfGroup(name: $0.name, count: $0.count) }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

/// The group list itself: each name with its count, selection by click.
private struct ShelfGroupRows: View {
    let groups: [ShelfGroup]
    let choose: (String) -> Void

    var body: some View {
        ForEach(groups) { group in
            Button {
                choose(group.name)
            } label: {
                HStack {
                    Text(group.name)
                        .lineLimit(2)
                    Spacer()
                    Text("\(group.count)")
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// The way back up from a group's works to the group list.
private struct ShelfBackRow: View {
    let name: String
    let back: () -> Void

    var body: some View {
        HStack {
            Button {
                back()
            } label: {
                Label(name, systemImage: "chevron.left")
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(8)
    }
}

// MARK: - The PDF library

/// One PDF in the Reader Library, as the folder tells it.
private struct PDFFile: Identifiable {
    let url: URL
    let modified: Date
    let bytes: Int

    var id: String { url.path }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// A PDF with what the shelf knows of it: its record and that
/// record's BibTeX, when the work has been shelved.
private struct PDFEntry: Identifiable {
    let file: PDFFile
    let doc: LiquidDoc?
    let record: BibTeXRecord?

    var id: String { file.id }
    var title: String {
        doc.map(SourcesView.displayTitle(of:)) ?? file.name
    }
}

struct PDFLibraryView: View {
    @Environment(AppState.self) private var state
    let listing: FileShelfListing

    @State private var files: [PDFFile] = []
    @State private var scanned = false
    @State private var search = ""
    @State private var selectedID: String?
    /// The open author or journal, on those listings; nil shows the names.
    @State private var selectedGroup: String?

    /// The shelved source standing for each PDF, keyed by the PDF's
    /// file name (lowercased) — built once from the records.
    private var shelvedByFileName: [String: LiquidDoc] {
        var map: [String: LiquidDoc] = [:]
        for entry in state.sourceEntries {
            let doc = entry.doc
            if let wrapped = doc.wraps?.file {
                map[wrapped.lowercased()] = doc
            }
            if let line = (doc.body ?? []).first(where: { $0.text.hasPrefix("PDF: ") })?.text {
                let rest = line.dropFirst("PDF: ".count)
                let name = rest.range(of: " — kept in ").map { String(rest[..<$0.lowerBound]) }
                    ?? String(rest)
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { map[trimmed.lowercased()] = doc }
            }
        }
        return map
    }

    /// Every PDF with its record, titles A–Z.
    private var entries: [PDFEntry] {
        let shelved = shelvedByFileName
        return files.map { file in
            let doc = shelved[file.url.lastPathComponent.lowercased()]
            let record = doc?.references.first.flatMap { BibTeXRecord.parse($0.bibtex) }
            return PDFEntry(file: file, doc: doc, record: record)
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func matches(_ entry: PDFEntry) -> Bool {
        search.isEmpty
            || entry.title.localizedCaseInsensitiveContains(search)
            || entry.file.name.localizedCaseInsensitiveContains(search)
            || (entry.record?.displayAuthors.localizedCaseInsensitiveContains(search) ?? false)
    }

    /// The listing's works: all of them (Alphabetical), or the open
    /// group's — by the record's authors or its journal.
    private func shownEntries(of all: [PDFEntry]) -> [PDFEntry] {
        var shown = all
        switch listing {
        // Not Imported belongs to the EPUB shelf; here it never
        // arrives, and would read as the plain list.
        case .alphabetical, .notImported:
            break
        case .authors:
            guard let selectedGroup else { return [] }
            shown = shown.filter {
                $0.record?.individualAuthors.contains {
                    $0.caseInsensitiveCompare(selectedGroup) == .orderedSame
                } == true
            }
        case .journals:
            guard let selectedGroup else { return [] }
            shown = shown.filter {
                venue(of: $0.record)?.caseInsensitiveCompare(selectedGroup) == .orderedSame
            }
        }
        return shown.filter(matches)
    }

    private func groups(of all: [PDFEntry]) -> [ShelfGroup] {
        switch listing {
        case .alphabetical, .notImported: return []
        case .authors: return gatherGroups(all.flatMap { $0.record?.individualAuthors ?? [] })
        case .journals: return gatherGroups(all.compactMap { venue(of: $0.record) })
        }
    }

    var body: some View {
        let all = entries
        Group {
            if state.readerLibraryURL == nil {
                emptyShelf
            } else if files.isEmpty && scanned {
                placeholder("PDF Library",
                            message: "No PDFs in the Reader Library folder yet. They appear here as they arrive; each opens into Reader.")
            } else {
                HStack(spacing: 0) {
                    listColumn(all: all)
                        .frame(width: 300)
                    Divider()
                    if let entry = all.first(where: { $0.id == selectedID }) {
                        // A shelved work answers with its library record —
                        // where quotes, annotations, and citations gather;
                        // only a PDF not yet on the shelf shows as a file.
                        if let doc = entry.doc {
                            SourcePageView(doc: doc, record: entry.record)
                                .id(doc.id)
                        } else {
                            PDFFilePage(file: entry.file)
                                .id(entry.id)
                        }
                    } else {
                        placeholder("PDF Library",
                                    message: listing == .alphabetical
                                        ? "The Reader Library's works, every title A–Z. Choose one — its record opens here; the PDF itself opens into Reader."
                                        : listing == .authors
                                        ? "The writers on the shelf, their works under them."
                                        : "The journals and proceedings the works appeared in, as their records tell it.")
                    }
                }
            }
        }
        .greyColumnAppearance()
        .task { rescan() }
    }

    private func listColumn(all: [PDFEntry]) -> some View {
        VStack(spacing: 0) {
            if listing != .alphabetical, let selectedGroup {
                ShelfBackRow(name: selectedGroup) { self.selectedGroup = nil }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if listing != .alphabetical, selectedGroup == nil, search.isEmpty {
                        ShelfGroupRows(groups: groups(of: all)) { selectedGroup = $0 }
                    } else if listing != .alphabetical, selectedGroup == nil {
                        // A search on a name listing looks across every
                        // work, so nothing hides behind a name.
                        ForEach(all.filter(matches)) { entry in
                            row(entry)
                        }
                    } else {
                        ForEach(shownEntries(of: all)) { entry in
                            row(entry)
                        }
                    }
                }
                .padding(8)
            }
            .searchable(text: $search, placement: .automatic, prompt: "Title, author, or file name")
            Divider()
            HStack {
                Button("Rescan") { rescan() }
                    .help("Walks the Reader Library folder again")
                Spacer()
                Text("\(files.count.formatted()) PDFs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
        }
    }

    private func row(_ entry: PDFEntry) -> some View {
        Button {
            selectedID = entry.id
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .fontWeight(.medium)
                    .lineLimit(2)
                Text("\(entry.file.modified.formatted(date: .abbreviated, time: .omitted)) · \(Self.sizeText(entry.file.bytes))\(entry.doc == nil ? " · not on the shelf" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selectedID == entry.id
                        ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            Button("Open in Reader") { NSWorkspace.shared.open(entry.file.url) }
            Button("Print Booklet\u{2026}") {
                state.printBooklet(from: entry.file.url)
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([entry.file.url])
            }
        }
    }

    /// Walks the granted Reader Library for PDFs — names and dates
    /// only; the files are read, never touched.
    private func rescan() {
        guard let reader = state.readerLibraryURL else { return }
        var found: [PDFFile] = []
        let enumerator = FileManager.default.enumerator(
            at: reader,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "pdf" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey,
                                                           .fileSizeKey])
            found.append(PDFFile(url: url,
                                 modified: values?.contentModificationDate ?? .distantPast,
                                 bytes: values?.fileSize ?? 0))
        }
        files = found
        scanned = true
    }

    static func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private var emptyShelf: some View {
        VStack(spacing: 12) {
            placeholder("PDF Library",
                        message: "The Reader Library's PDFs, listed here as the folder holds them and opened into Reader. Grant the folder once and it is remembered.")
                .frame(maxHeight: 280, alignment: .bottom)
            Button("Choose the Reader Library…") { chooseReaderLibrary() }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        rescan()
    }

    private func placeholder(_ title: String, message: String) -> some View {
        ShelfPlaceholder(title: title, message: message, systemImage: "doc.text")
    }
}

/// A PDF not yet on the shelf: its file facts, the doors to it, and
/// the way onto the shelf. (A shelved PDF answers with its library
/// record instead — the shelf routes there before reaching here.)
private struct PDFFilePage: View {
    let file: PDFFile

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(file.name)
                    .font(.system(size: 26, weight: .bold, design: .serif))
                Text("\(file.modified.formatted(date: .long, time: .shortened)) · \(PDFLibraryView.sizeText(file.bytes))")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Open in Reader") { NSWorkspace.shared.open(file.url) }
                        .help("Hands the PDF to the Mac's PDF app — Reader, where Reader owns PDFs")
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([file.url])
                    }
                }
                .buttonStyle(GreyColumnButtonStyle())
                .fixedSize()
                Divider()
                Text("Not on the shelf yet — a Visual-Meta PDF joins it on the next scan (Settings ▸ Library ▸ Scan Now), or drop the file on the Sources shelf.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppGreys.page)
    }
}

// MARK: - The EPUB library

/// One place on the EPUB shelf: a file in the EPUB Library (paired
/// with its record when the name says which), or a record whose EPUB
/// still stands in the community folder.
private struct EPUBShelfEntry: Identifiable {
    var url: URL?
    var doc: LiquidDoc?
    var record: BibTeXRecord?
    var modified: Date

    var id: String { url?.path ?? doc?.id ?? "empty" }
    var title: String {
        if let doc { return SourcesView.displayTitle(of: doc) }
        return url?.deletingPathExtension().lastPathComponent ?? ""
    }
    /// Whose work it is, for the Authors listing: the record's authors
    /// where a record stands, the document's author otherwise.
    var authorNames: [String] {
        if let record, !record.individualAuthors.isEmpty { return record.individualAuthors }
        if let doc, !doc.author.isEmpty { return [doc.author] }
        return []
    }
}

struct EPUBLibraryView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    let listing: FileShelfListing

    @State private var search = ""
    @State private var selectedID: String?
    @State private var selectedGroup: String?
    @State private var files: [URL] = []
    /// The work open for reading in the shelf's own pane — the whole
    /// book, right here; nil shows the record.
    @State private var readingDocID: String?

    /// The shelf: the EPUB Library folder's files, each paired with
    /// its record where the name tells; then any imported work whose
    /// EPUB is not among them (kept in the community folder).
    private var entries: [EPUBShelfEntry] {
        var result: [EPUBShelfEntry] = []
        var pairedIDs: Set<String> = []
        func record(of doc: LiquidDoc?) -> BibTeXRecord? {
            doc?.references.first.flatMap { BibTeXRecord.parse($0.bibtex) }
        }
        for url in files {
            let doc = state.pairedEPUBDocument(forFileName: url.lastPathComponent)
            if let doc { pairedIDs.insert(doc.id) }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            result.append(EPUBShelfEntry(url: url, doc: doc, record: record(of: doc),
                                         modified: modified))
        }
        let recordOnly = state.index.byID.values.map(\.doc)
            .filter { !pairedIDs.contains($0.id) && state.epubCompanionURL(for: $0) != nil }
            .map { EPUBShelfEntry(url: nil, doc: $0, record: record(of: $0),
                                  modified: $0.listedDate) }
        result.append(contentsOf: recordOnly)
        return result.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private func matches(_ entry: EPUBShelfEntry) -> Bool {
        search.isEmpty
            || entry.title.localizedCaseInsensitiveContains(search)
            || entry.authorNames.contains { $0.localizedCaseInsensitiveContains(search) }
    }

    private func shownEntries(of all: [EPUBShelfEntry]) -> [EPUBShelfEntry] {
        // Not Imported is the files still outside the library; the
        // named listings show fully imported works only.
        var shown = listing == .notImported
            ? all.filter { $0.doc == nil }
            : all.filter { $0.doc != nil }
        switch listing {
        case .alphabetical, .notImported:
            break
        case .authors:
            guard let selectedGroup else { return [] }
            shown = shown.filter {
                $0.authorNames.contains {
                    $0.caseInsensitiveCompare(selectedGroup) == .orderedSame
                }
            }
        case .journals:
            guard let selectedGroup else { return [] }
            shown = shown.filter {
                venue(of: $0.record)?.caseInsensitiveCompare(selectedGroup) == .orderedSame
            }
        }
        return shown.filter(matches)
    }

    private func groups(of all: [EPUBShelfEntry]) -> [ShelfGroup] {
        let imported = all.filter { $0.doc != nil }
        switch listing {
        case .alphabetical, .notImported: return []
        case .authors: return gatherGroups(imported.flatMap(\.authorNames))
        case .journals: return gatherGroups(imported.compactMap { venue(of: $0.record) })
        }
    }

    var body: some View {
        let all = entries
        Group {
            if all.isEmpty {
                emptyShelf
            } else if listing == .journals, groups(of: all).isEmpty {
                placeholder(message: "None of the EPUBs' records name a journal or proceedings yet — that arrives with their BibTeX.")
            } else {
                HStack(spacing: 0) {
                    listColumn(all: all)
                        .frame(width: 300)
                    Divider()
                    if let entry = all.first(where: { $0.id == selectedID }) {
                        if let doc = entry.doc, readingDocID == doc.id {
                            // The book itself, read in place — the same
                            // reader the library uses: citations
                            // resolved, images, tables, the daggers.
                            readingPane(doc)
                                .id(doc.id)
                        } else if let doc = entry.doc {
                            SourcePageView(doc: doc, record: entry.record,
                                           readAction: { readingDocID = doc.id })
                                .id(doc.id)
                        } else if let url = entry.url {
                            EPUBFilePage(url: url)
                                .id(url.path)
                        }
                    } else {
                        placeholder(message: listing == .alphabetical
                            ? "The library's imported works, every title A–Z — each reads whole, right here."
                            : listing == .authors
                            ? "The writers on the shelf, their imported works under them."
                            : listing == .journals
                            ? "The journals and proceedings the works appeared in, as their records tell it."
                            : "EPUB files not yet read into the library — each is one Import away, and moves up into the listings once it arrives.")
                    }
                }
            }
        }
        .greyColumnAppearance()
        .task { rescan() }
        .onChange(of: state.index.isScanning) { _, scanning in
            if !scanning { rescan() }
        }
        // Choosing another work lands on its record, not mid-read of
        // the last one.
        .onChange(of: selectedID) { readingDocID = nil }
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
        }
    }

    /// The whole work in the reader, the record one step back.
    private func readingPane(_ doc: LiquidDoc) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    readingDocID = nil
                } label: {
                    Label("Record", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .help("Back to the work's record — its citation, quotes, and annotations")
                Spacer()
            }
            .padding(10)
            Divider()
            // The book reader — Scroll | Horizontal, the fold, the
            // reading menu — the same reading the library gives.
            OrigamiReadingView(doc: doc)
        }
        .background(AppGreys.page)
    }

    private func listColumn(all: [EPUBShelfEntry]) -> some View {
        VStack(spacing: 0) {
            if listing != .alphabetical, let selectedGroup {
                ShelfBackRow(name: selectedGroup) { self.selectedGroup = nil }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if listing != .alphabetical, selectedGroup == nil, search.isEmpty {
                        ShelfGroupRows(groups: groups(of: all)) { selectedGroup = $0 }
                    } else if listing != .alphabetical, selectedGroup == nil {
                        ForEach(all.filter(matches)) { entry in
                            row(entry)
                        }
                    } else {
                        ForEach(shownEntries(of: all)) { entry in
                            row(entry)
                        }
                    }
                }
                .padding(8)
            }
            .searchable(text: $search, placement: .automatic, prompt: "Title or author")
            Divider()
            HStack {
                Text("\(all.count.formatted()) EPUBs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Drop an EPUB to add one")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
        }
    }

    private func row(_ entry: EPUBShelfEntry) -> some View {
        Button {
            selectedID = entry.id
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .fontWeight(.medium)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let doc = entry.doc {
                        // The venue rides in the caption — the journal
                        // or publisher the record names, when it does.
                        Text([doc.author, doc.listedDateText,
                              venue(of: entry.record) ?? ""]
                            .filter { !$0.isEmpty }
                            .joined(separator: " · "))
                    } else {
                        Text("\(entry.modified.formatted(date: .abbreviated, time: .omitted)) · not imported yet")
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
        // A double click reads the book in a window of its own.
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if let doc = entry.doc {
                openWindow(id: "reading", value: doc.id)
            }
        })
        .background(selectedID == entry.id
                        ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            if let doc = entry.doc {
                Button("Read") {
                    selectedID = entry.id
                    readingDocID = doc.id
                }
                Button("Read in New Window") {
                    openWindow(id: "reading", value: doc.id)
                }
            } else if let url = entry.url {
                Button("Import") { state.importOrigamiEPUB(from: url) }
            }
            if let epub = entry.url ?? entry.doc.flatMap(state.epubCompanionURL(for:)) {
                Button("Print Booklet\u{2026}") {
                    state.printBooklet(from: epub)
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([epub])
                }
            }
            Divider()
            // The work whole: the file, and an imported work's
            // document and annotations with it.
            Button("Move to Trash", role: .destructive) {
                let moved = state.trashEPUBWork(
                    epub: entry.url ?? entry.doc.flatMap(state.epubCompanionURL(for:)),
                    doc: entry.doc)
                if moved {
                    if selectedID == entry.id { selectedID = nil }
                    rescan()
                }
            }
        }
    }

    /// Lists the EPUB Library folder — names and dates; the files are
    /// read, never touched.
    private func rescan() {
        guard let folder = state.epubLibraryURL else {
            files = []
            return
        }
        let found = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        files = found.filter { $0.pathExtension.lowercased() == "epub" }
    }

    /// A dropped EPUB imports; with an EPUB Library granted the copy
    /// lands there, so the shelf shows it either way.
    private func handleDrop(_ urls: [URL]) -> Bool {
        var added = false
        for url in urls where url.isFileURL && url.pathExtension.lowercased() == "epub" {
            state.importOrigamiEPUB(from: url)
            added = true
        }
        return added
    }

    private var emptyShelf: some View {
        VStack(spacing: 12) {
            placeholder(message: state.epubLibraryURL == nil
                ? "Your EPUBs' own folder — the Reader Library's twin. Grant it once and the shelf lists it; importing a work reads it whole into the library, and an Origami EPUB arrives with its text, glossary, citations, and images. Or simply drop an EPUB here."
                : "No EPUBs in the EPUB Library folder yet. Drop one here — it is read whole into the library, and the file joins the folder.")
                .frame(maxHeight: 300, alignment: .bottom)
            if state.epubLibraryURL == nil {
                Button("Choose the EPUB Library…") { chooseEPUBLibrary() }
                    .buttonStyle(.borderedProminent)
                Text("Settings ▸ Library holds the same door.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func chooseEPUBLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder where your EPUBs live (the EPUB Library)."
        panel.prompt = "Grant"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.chooseEPUBLibrary(url)
        rescan()
    }

    private func placeholder(message: String) -> some View {
        ShelfPlaceholder(title: "EPUB Library", message: message, systemImage: "book")
    }
}

/// An EPUB not yet imported: its file facts and the one door in.
private struct EPUBFilePage: View {
    @Environment(AppState.self) private var state
    let url: URL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.system(size: 26, weight: .bold, design: .serif))
                if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey,
                                                                  .fileSizeKey]) {
                    Text("\(values.contentModificationDate?.formatted(date: .long, time: .shortened) ?? "") · \(PDFLibraryView.sizeText(values.fileSize ?? 0))")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Button("Import") { state.importOrigamiEPUB(from: url) }
                        .help("Reads the EPUB whole into a document in the community folder — an Origami EPUB with its text, glossary, citations, and images; a plain EPUB chapter by chapter. The file stays exactly where it is.")
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .buttonStyle(GreyColumnButtonStyle())
                .fixedSize()
                Text("Not imported yet — its words are not in the library until it is.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppGreys.page)
    }
}

/// The file shelves' quiet empty-state, hand-rolled like the Sources
/// shelf's: ContentUnavailableView disturbs split-view detail layout
/// on macOS — the white-column bug.
private struct ShelfPlaceholder: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview("PDF library") {
    PDFLibraryView(listing: .alphabetical)
        .environment(AppState())
        .frame(width: 900, height: 560)
}

#Preview("EPUB library") {
    EPUBLibraryView(listing: .alphabetical)
        .environment(AppState())
        .frame(width: 900, height: 560)
}
#endif
