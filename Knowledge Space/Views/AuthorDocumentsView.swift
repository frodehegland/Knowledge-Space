#if os(macOS)
import SwiftUI
import AppKit

// The Author section: Author's .liquid documents, read in place from
// the Author folder and listed by time, keyword, or name — organized
// here, written there. A click shows what the library knows of a
// document; Open in Author hands it to Author itself, the way a PDF
// goes to Reader.

/// How the list stands: by time (newest first, a month per group), by
/// keyword (the documents' own glossary terms), or by name.
private enum AuthorListing: String, CaseIterable, Identifiable {
    case time = "Time"
    case keywords = "Keywords"
    case name = "Name"
    var id: String { rawValue }
}

struct AuthorDocumentsView: View {
    @Environment(AppState.self) private var state

    @State private var listing: AuthorListing = .time
    @State private var search = ""
    @State private var selectedID: String?
    /// The open keyword on the Keywords listing — nil shows the terms.
    @State private var selectedKeyword: String?

    private var documents: [AuthorDocument] { state.authorDocuments }

    /// The documents the current listing and search leave standing.
    private var shownDocuments: [AuthorDocument] {
        var shown = documents
        if listing == .keywords, let selectedKeyword {
            shown = shown.filter {
                $0.keywords.contains { $0.caseInsensitiveCompare(selectedKeyword) == .orderedSame }
            }
        }
        guard !search.isEmpty else { return shown }
        return shown.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(search)
                || $0.publishingTitle.localizedCaseInsensitiveContains(search)
                || $0.text.localizedCaseInsensitiveContains(search)
                || $0.keywords.contains { $0.localizedCaseInsensitiveContains(search) }
                || $0.citedNames.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    /// Every glossary term across the shelf, with how many documents
    /// carry it — the Keywords listing's front page.
    private var allKeywords: [(name: String, count: Int)] {
        var counts: [String: (name: String, count: Int)] = [:]
        for document in documents {
            for keyword in document.keywords {
                let key = keyword.lowercased()
                counts[key] = (counts[key]?.name ?? keyword,
                               (counts[key]?.count ?? 0) + 1)
            }
        }
        return counts.values
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Group {
            if documents.isEmpty {
                emptyShelf
            } else {
                HStack(spacing: 0) {
                    listColumn
                        .frame(width: 300)
                    Divider()
                    if let document = documents.first(where: { $0.id == selectedID }) {
                        AuthorDocumentPage(document: document,
                                           showKeyword: { keyword in
                            listing = .keywords
                            selectedKeyword = keyword
                        })
                        .id(document.id)
                    } else {
                        placeholder("Author Documents",
                                    message: "Choose a document from the list. It opens in Author — the library only reads it.")
                    }
                }
            }
        }
        .greyColumnAppearance()
        .task { state.authorLibraryUpkeep() }
    }

    // MARK: The list column

    @ViewBuilder private var listColumn: some View {
        VStack(spacing: 0) {
            Picker("Listing", selection: $listing) {
                ForEach(AuthorListing.allCases) { choice in
                    Text(choice.rawValue).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            .onChange(of: listing) { selectedKeyword = nil }
            if listing == .keywords, let selectedKeyword {
                HStack {
                    Button {
                        self.selectedKeyword = nil
                    } label: {
                        Label(selectedKeyword, systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            }
            // A plain SwiftUI list, like the shelves — the AppKit-backed
            // List mislays its first layout inside a fixed-width column.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: .sectionHeaders) {
                    if listing == .keywords, selectedKeyword == nil, search.isEmpty {
                        keywordRows
                    } else if listing == .time {
                        timeSections
                    } else {
                        nameRows
                    }
                }
                .padding(8)
            }
            .searchable(text: $search, placement: .automatic,
                        prompt: "Name, text, keyword, or cited name")
            Divider()
            HStack {
                Button(state.authorScanRunning ? "Scanning…" : "Rescan") {
                    state.scanAuthorLibrary()
                }
                .disabled(state.authorScanRunning)
                .help("Walks the Author folder again — only documents that changed are re-read")
                Spacer()
                Text("\(shownDocuments.count.formatted()) of \(documents.count.formatted())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
        }
    }

    /// The Time listing: a month per group, newest first.
    @ViewBuilder private var timeSections: some View {
        let groups = Self.monthGroups(of: shownDocuments)
        ForEach(groups, id: \.title) { group in
            Section {
                ForEach(group.documents) { document in
                    row(document)
                }
            } header: {
                Text(group.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(AppGreys.page)
            }
        }
    }

    /// The Name listing — and any keyword's or search's answer — flat
    /// and alphabetical or by time as the listing says.
    @ViewBuilder private var nameRows: some View {
        let sorted = listing == .name
            ? shownDocuments.sorted {
                $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
            }
            : shownDocuments
        ForEach(sorted) { document in
            row(document)
        }
    }

    /// The Keywords listing's front page: every term, with its count.
    @ViewBuilder private var keywordRows: some View {
        ForEach(allKeywords, id: \.name) { keyword in
            Button {
                selectedKeyword = keyword.name
            } label: {
                HStack {
                    Text(keyword.name)
                    Spacer()
                    Text("\(keyword.count)")
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// One document in the list: its own icon where Author wrote one
    /// (the package's QuickLook preview — the document's Finder face),
    /// then its name, its date and measure.
    private func row(_ document: AuthorDocument) -> some View {
        Button {
            selectedID = document.id
        } label: {
            HStack(alignment: .center, spacing: 8) {
                if AuthorDocumentIcon.hasIcon(document) {
                    AuthorDocumentIconView(document: document, height: 38)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(document.displayTitle)
                        .fontWeight(.medium)
                        .lineLimit(2)
                    Text(rowDetail(document))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selectedID == document.id
                        ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            Button("Open in Author") { state.openInAuthor(document) }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([document.fileURL])
            }
        }
    }

    private func rowDetail(_ document: AuthorDocument) -> String {
        var parts = [document.created.formatted(date: .abbreviated, time: .omitted)]
        if document.wordCount > 0 {
            parts.append("\(document.wordCount.formatted()) words")
        }
        return parts.joined(separator: " · ")
    }

    /// The documents a month at a time, newest month first, each
    /// month's documents newest first.
    private static func monthGroups(of documents: [AuthorDocument])
        -> [(title: String, documents: [AuthorDocument])] {
        let calendar = Calendar.current
        var order: [Date] = []
        var byMonth: [Date: [AuthorDocument]] = [:]
        for document in documents.sorted(by: { $0.created > $1.created }) {
            let month = calendar.date(from: calendar.dateComponents([.year, .month],
                                                                    from: document.created))
                ?? document.created
            if byMonth[month] == nil { order.append(month) }
            byMonth[month, default: []].append(document)
        }
        return order.map { month in
            (month.formatted(.dateTime.month(.wide).year()), byMonth[month] ?? [])
        }
    }

    // MARK: Empty and placeholder states

    /// Hand-rolled, deliberately: ContentUnavailableView disturbs
    /// split-view detail layout on macOS — the white-column bug.
    private func placeholder(_ title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.richtext")
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

    private var emptyShelf: some View {
        VStack(spacing: 12) {
            placeholder("Author Documents",
                        message: "The library reads Author's .liquid documents in place — their names, dates, glossary terms, cited names, and text — so they can be found here by time and keyword, and opened in Author. It looks in Author's iCloud folder unless another is chosen; the folder is granted once and remembered.")
                .frame(maxHeight: 280, alignment: .bottom)
            if state.authorFolderIsReadable {
                Button(state.authorScanRunning ? "Scanning…" : "Scan the Author Folder") {
                    state.scanAuthorLibrary()
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.authorScanRunning)
            } else {
                Button("Choose the Author Folder…") { chooseAuthorFolder() }
                    .buttonStyle(.borderedProminent)
            }
            Text(state.effectiveAuthorFolderURL.path)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The one-time grant: the panel opens on Author's own iCloud
    /// folder — Choose is usually all there is to it.
    private func chooseAuthorFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = AuthorLibraryScanner.defaultFolder
        panel.message = "Choose the folder where Author keeps its .liquid documents."
        panel.prompt = "Grant"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.chooseAuthorLibrary(url)
    }
}

// MARK: - One document's icon

/// One document's icon, asked of the system the way the Finder's icon
/// view asks — the decorated document face, loaded as the row appears
/// and cached. The square is held from the start, so the icon's
/// arrival never shifts the row's words.
private struct AuthorDocumentIconView: View {
    let document: AuthorDocument
    let height: CGFloat
    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.clear
            }
        }
        .frame(width: height, height: height)
        .task(id: "\(document.id)|\(document.stamp)") {
            icon = await AuthorDocumentIcon.icon(for: document, height: height)
        }
    }
}

// MARK: - One document's page

/// What the library knows of one Author document: its names and dates,
/// its glossary terms and cited names, and the opening of its text —
/// with Author itself one click away.
private struct AuthorDocumentPage: View {
    @Environment(AppState.self) private var state
    let document: AuthorDocument
    /// Clicking a term narrows the list to it.
    let showKeyword: (String) -> Void

    /// How much of the text the page shows — enough to know the
    /// document; the whole of it lives in Author.
    private static let previewCap = 4_000

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(document.displayTitle)
                    .font(.system(size: 26, weight: .bold, design: .serif))
                HStack(spacing: 6) {
                    if !document.authorName.isEmpty { Text(document.authorName) }
                    Text("· \(document.created.formatted(date: .long, time: .omitted))")
                    if document.wordCount > 0 {
                        Text("· \(document.wordCount.formatted()) words")
                    }
                }
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button("Open in Author") { state.openInAuthor(document) }
                        .help("Hands the document to Author — the library only reads it")
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([document.fileURL])
                    }
                }
                .buttonStyle(GreyColumnButtonStyle())
                .fixedSize()

                details

                if !document.keywords.isEmpty {
                    Divider()
                    termSection("Glossary terms", terms: document.keywords, icon: "tag",
                                help: "A term the document defines — click to see every document carrying it")
                }
                if !document.citedNames.isEmpty {
                    Divider()
                    citedSection
                }
                if !document.text.isEmpty {
                    Divider()
                    Text(String(document.text.prefix(Self.previewCap)))
                        .font(.system(size: 15, design: .serif))
                        .textSelection(.enabled)
                    if document.text.count > Self.previewCap {
                        Text("The text continues — open the document in Author to read it whole.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                } else if !document.isPackage {
                    Divider()
                    Text("A document from an earlier Author — listed by name and date; Author still opens it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppGreys.page)
    }

    /// The quieter facts, one line each, only where they say something.
    @ViewBuilder private var details: some View {
        let rows: [(String, String)] = [
            ("Publishing title",
             document.publishingTitle == document.displayTitle ? "" : document.publishingTitle),
            ("Institution", document.institution),
            ("Course", document.course),
            ("Module", document.module),
            ("Last changed",
             document.modified.formatted(date: .abbreviated, time: .shortened)),
        ].filter { !$0.1.isEmpty }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(rows, id: \.0) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(row.0)
                            .foregroundStyle(.tertiary)
                            .frame(width: 110, alignment: .trailing)
                        Text(row.1)
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func termSection(_ title: String, terms: [String], icon: String,
                             help: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.system(size: 15, design: .serif))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)],
                      alignment: .leading, spacing: 6) {
                ForEach(terms, id: \.self) { term in
                    Button {
                        showKeyword(term)
                    } label: {
                        Text(term)
                            .lineLimit(1)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help(help)
                }
            }
        }
    }

    private var citedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Cites", systemImage: "person.text.rectangle")
                .font(.system(size: 15, design: .serif))
                .foregroundStyle(.secondary)
            Text(document.citedNames.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

#Preview("Author documents") {
    AuthorDocumentsView()
        .environment(AppState())
        .frame(width: 900, height: 560)
}
#endif
