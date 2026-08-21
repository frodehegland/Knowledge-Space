import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

// Citations & multi-medium sources — the consumer side of Author's
// EPUB export metadata (origami.json / the metadata island), per the
// implementation brief of 2026-08-18: every reference may name the
// manifestations the author consulted (EPUB, PDF, web, file), each
// resolvable against the reader's own libraries by filename and
// digest — never by path — and openable in its medium.
//
// The in-text rendering half of the brief (§3) is already the app's:
// the EPUB importer turns biblioref anchors into [cite:key] tokens
// with the file's own numbers, and the citation display setting
// (Author–Date / Numbered / Superscript) applies live.

// MARK: - §2 The metadata models

/// Author's export metadata, as far as the sources pipeline needs it.
/// Unknown keys are ignored throughout — the format grows.
nonisolated struct OrigamiMetadata: Codable, Sendable {
    var document: DocumentBlock?
    var references: [String: Reference]?   // key == data-citation-key

    struct DocumentBlock: Codable, Sendable {
        var id: String?        // "urn:uuid:…"
        var digest: String?    // "sha256:<hex>"
        var title: String?
        var filename: String?
        var bibtex: String?
    }

    struct Reference: Codable, Sendable {
        var bibtex: String?
        var csl: CSL?
        var sources: [Source]?   // manifestations; absent on older exports
    }

    struct CSL: Codable, Sendable {
        var title: String?
        var author: [Name]?
        /// The year. CSL in the wild also writes issued as a
        /// date-parts object; both forms decode.
        var issued: Int?
        var DOI: String?
        var URL: String?
        var containerTitle: String?

        struct Name: Codable, Sendable {
            var family: String?
            var given: String?
        }

        private enum CodingKeys: String, CodingKey {
            case title, author, issued, DOI, URL
            case containerTitle = "container-title"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try? container.decodeIfPresent(String.self, forKey: .title)
            author = try? container.decodeIfPresent([Name].self, forKey: .author)
            DOI = try? container.decodeIfPresent(String.self, forKey: .DOI)
            URL = try? container.decodeIfPresent(String.self, forKey: .URL)
            containerTitle = try? container.decodeIfPresent(String.self,
                                                            forKey: .containerTitle)
            if let year = try? container.decodeIfPresent(Int.self, forKey: .issued) {
                issued = year
            } else if let parts = try? container.decodeIfPresent(DateParts.self,
                                                                 forKey: .issued) {
                issued = parts.dateParts?.first?.first
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(title, forKey: .title)
            try container.encodeIfPresent(author, forKey: .author)
            try container.encodeIfPresent(issued, forKey: .issued)
            try container.encodeIfPresent(DOI, forKey: .DOI)
            try container.encodeIfPresent(URL, forKey: .URL)
            try container.encodeIfPresent(containerTitle, forKey: .containerTitle)
        }

        private struct DateParts: Codable {
            var dateParts: [[Int]]?
            enum CodingKeys: String, CodingKey { case dateParts = "date-parts" }
        }
    }

    struct Source: Codable, Sendable {
        var medium: String     // "epub" | "pdf" | "web" | "file"
        var role: String?      // "consulted" | "canonical" | "alternate"
        var filename: String? = nil  // local manifestations — no paths
        var digest: String? = nil    // "sha256:<hex>" of the file bytes
        var id: String? = nil        // Origami document id when itself an Origami EPUB
        var fragment: String? = nil  // EPUB deep link: an H-/P- element id
        var page: Int? = nil         // PDF deep link, 1-based
        var url: String? = nil       // web manifestations

        var isConsulted: Bool {
            role?.caseInsensitiveCompare("consulted") == .orderedSame
        }

        /// The button word for the medium.
        var mediumLabel: String {
            switch medium.lowercased() {
            case "epub": "EPUB"
            case "pdf": "PDF"
            case "web": "Web"
            default: "File"
            }
        }
    }
}

// MARK: - §1 Loading the metadata from an EPUB

extension OrigamiMetadata {
    /// The metadata out of an Origami EPUB: the OEBPS/origami.json
    /// sidecar first, the mirror island in content.xhtml's head second
    /// (byte-identical by contract). Nil when the package carries
    /// neither — an older or foreign EPUB.
    static func load(fromEPUB url: URL) -> OrigamiMetadata? {
        guard let data = try? Data(contentsOf: url),
              let zip = try? ZipReader(data: data) else { return nil }
        let json = zip.entry("OEBPS/origami.json")
            ?? zip.entries.first { $0.key.hasSuffix("origami.json") }?.value
            ?? island(in: zip)
        return json.flatMap { try? JSONDecoder().decode(OrigamiMetadata.self, from: $0) }
    }

    /// The mirror island: <script type="application/json"
    /// id="origami-metadata"> — directly parseable JSON.
    private static func island(in zip: ZipReader) -> Data? {
        guard let entry = zip.entries.first(where: {
            $0.key.hasSuffix("content.xhtml") || $0.key.hasSuffix("content/paper.html")
        })?.value,
              let html = String(data: entry, encoding: .utf8),
              let mark = html.range(of: "id=\"origami-metadata\">") else { return nil }
        let after = html[mark.upperBound...]
        guard let end = after.range(of: "</script>") else { return nil }
        return Data(after[..<end.lowerBound].utf8)
    }
}

// MARK: - §4 Resolution of one source to something openable

/// One manifestation, resolved against the reader's own libraries.
nonisolated struct ResolvedCitationSource: Identifiable {
    enum Availability {
        /// An Origami document already in the library — the strongest
        /// identity; opens in the book reader.
        case libraryDocument(LiquidDoc)
        /// A local file. `verified` means its digest matched the cited
        /// one; `changed` means a digest was cited and no file matched
        /// it (the file has changed since it was cited).
        case local(URL, verified: Bool, changed: Bool)
        case web(URL)
        /// Named but nowhere in the library — shown greyed, never
        /// hidden: the reader should see the author consulted it.
        case missing
    }

    let source: OrigamiMetadata.Source
    let availability: Availability

    var id: String {
        source.medium + "|" + (source.filename ?? source.url ?? source.id ?? "")
    }

    var isResolvable: Bool {
        if case .missing = availability { return false }
        return true
    }
}

extension AppState {

    /// The Author-export metadata riding with a document's EPUB
    /// companion, parsed once and cached by the companion's digest.
    func authorMetadata(for doc: LiquidDoc) -> OrigamiMetadata? {
        guard let companion = epubCompanionURL(for: doc),
              let digest = FileHasher.sha256Hex(of: companion) else { return nil }
        if let cached = origamiMetadataByDigest[digest] { return cached }
        let parsed = OrigamiMetadata.load(fromEPUB: companion)
        origamiMetadataByDigest[digest] = parsed
        return parsed
    }

    /// Every manifestation of one cited reference, resolved — the
    /// export's own sources array, or (§7) web sources derived from
    /// CSL and BibTeX so older exports travel the same pipeline. Array
    /// order is the author's preference order, preserved.
    func citationSources(for key: String, in doc: LiquidDoc) -> [ResolvedCitationSource] {
        let reference = authorMetadata(for: doc)?.references?[key]
        var sources = reference?.sources ?? []
        if sources.isEmpty {
            sources = Self.derivedSources(
                from: reference,
                bibtex: doc.references.first { $0.id == key }?.bibtex)
        }
        return sources.map { resolveCitationSource($0) }
    }

    /// §7: a reference without sources still gets web manifestations —
    /// the CSL's DOI as canonical, its URL as alternate; failing CSL,
    /// the same fields out of the BibTeX.
    nonisolated static func derivedSources(from reference: OrigamiMetadata.Reference?,
                                           bibtex: String?) -> [OrigamiMetadata.Source] {
        var doi = reference?.csl?.DOI?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var url = reference?.csl?.URL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if doi.isEmpty, url.isEmpty, let bibtex,
           let record = BibTeXRecord.records(in: bibtex).first {
            doi = record.fields["doi"] ?? ""
            url = record.fields["url"] ?? ""
        }
        var derived: [OrigamiMetadata.Source] = []
        if !doi.isEmpty {
            let doiURL = doi.hasPrefix("http") ? doi : "https://doi.org/" + doi
            derived.append(OrigamiMetadata.Source(medium: "web", role: "canonical",
                                                  url: doiURL))
            if !url.isEmpty, url != doiURL {
                derived.append(OrigamiMetadata.Source(medium: "web", role: "alternate",
                                                      url: url))
            }
        } else if !url.isEmpty {
            derived.append(OrigamiMetadata.Source(medium: "web", role: "alternate",
                                                  url: url))
        }
        return derived
    }

    /// §4's ladder: web needs only its URL; an Origami id already in
    /// the library is the strongest identity; otherwise the filename
    /// matches against the libraries, digests verifying when present.
    func resolveCitationSource(_ source: OrigamiMetadata.Source) -> ResolvedCitationSource {
        if source.medium.lowercased() == "web" {
            if let raw = source.url, let url = URL(string: raw) {
                return ResolvedCitationSource(source: source, availability: .web(url))
            }
            return ResolvedCitationSource(source: source, availability: .missing)
        }
        if let id = source.id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            let bare = id.replacingOccurrences(of: "urn:uuid:", with: "")
            if let entry = index.allByID[id] ?? index.allByID[bare] {
                return ResolvedCitationSource(source: source,
                                              availability: .libraryDocument(entry.doc))
            }
        }
        guard let filename = source.filename, !filename.isEmpty else {
            return ResolvedCitationSource(source: source, availability: .missing)
        }
        let candidates = fileCandidates(named: filename)
        guard !candidates.isEmpty else {
            return ResolvedCitationSource(source: source, availability: .missing)
        }
        let cited = source.digest?
            .replacingOccurrences(of: "sha256:", with: "").lowercased()
        if let cited, !cited.isEmpty {
            if let match = candidates.first(where: { FileHasher.sha256Hex(of: $0) == cited }) {
                return ResolvedCitationSource(source: source,
                                              availability: .local(match, verified: true,
                                                                   changed: false))
            }
            // A digest was cited and nothing matches it: the file has
            // changed since it was cited — still openable, marked.
            return ResolvedCitationSource(source: source,
                                          availability: .local(newest(of: candidates),
                                                               verified: false,
                                                               changed: true))
        }
        if candidates.count == 1 {
            return ResolvedCitationSource(source: source,
                                          availability: .local(candidates[0],
                                                               verified: false,
                                                               changed: false))
        }
        return ResolvedCitationSource(source: source,
                                      availability: .local(newest(of: candidates),
                                                           verified: false,
                                                           changed: false))
    }

    /// Filenames match by last path component, case-insensitively,
    /// across the community folder and the two file libraries — never
    /// by path (§4).
    private func fileCandidates(named filename: String) -> [URL] {
        let lowered = filename.lowercased()
        var results: [URL] = []
        let folders = [index.folderURL, epubLibraryURL, readerLibraryURL].compactMap { $0 }
        for folder in folders {
            guard let enumerator = FileManager.default.enumerator(
                at: folder,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator
            where url.lastPathComponent.lowercased() == lowered {
                results.append(url)
            }
        }
        return results
    }

    private nonisolated func newest(of candidates: [URL]) -> URL {
        candidates.max { first, second in
            let a = (try? first.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let b = (try? second.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return a < b
        } ?? candidates[0]
    }

    // MARK: §5 Opening a source, per medium

    func open(_ resolved: ResolvedCitationSource) {
        switch resolved.availability {
        case .libraryDocument(let target):
            openInLibrary(target, fragment: resolved.source.fragment)
        case .web(let url):
            NSWorkspace.shared.open(url)
        case .local(let url, _, _):
            switch resolved.source.medium.lowercased() {
            case "epub":
                // An EPUB already adopted opens as its library document,
                // at the cited fragment; a new one imports first.
                if let paired = pairedEPUBDocument(forFileName: url.lastPathComponent) {
                    openInLibrary(paired, fragment: resolved.source.fragment)
                } else {
                    importOrigamiEPUB(from: url, openWhenReady: true)
                }
            case "pdf":
                Self.openPDFWindow(url: url, page: resolved.source.page)
            default:
                NSWorkspace.shared.open(url)
            }
        case .missing:
            showNote("\u{201C}\(resolved.source.filename ?? "The file")\u{201D} isn\u{2019}t in your library.")
        }
    }

    /// §6's auto-open, when "Open sources in" is not Always Ask: the
    /// preferred medium's consulted manifestation, then the preferred
    /// medium, then anything consulted, then whatever resolves —
    /// author's order within each tier. False shows the dialog.
    func autoOpenCitation(key: String, in doc: LiquidDoc, preferred: String) -> Bool {
        let resolvable = citationSources(for: key, in: doc).filter(\.isResolvable)
        guard !resolvable.isEmpty else { return false }
        let tiers: [(ResolvedCitationSource) -> Bool] = [
            { $0.source.medium.lowercased() == preferred && $0.source.isConsulted },
            { $0.source.medium.lowercased() == preferred },
            { $0.source.isConsulted },
            { _ in true },
        ]
        for tier in tiers {
            if let first = resolvable.first(where: tier) {
                open(first)
                return true
            }
        }
        return false
    }

    // MARK: The PDF page window

    /// A small PDFKit window of its own — the one place in the app a
    /// cited PDF opens at its cited page. Windows are kept alive in a
    /// static shelf; closing one releases nothing else.
    @MainActor private static var pdfWindows: [NSWindow] = []

    @MainActor static func openPDFWindow(url: URL, page: Int?) {
        let controller = NSHostingController(
            rootView: CitedPDFView(url: url, page: page ?? 1))
        let window = NSWindow(contentViewController: controller)
        window.title = url.lastPathComponent
        window.setContentSize(NSSize(width: 760, height: 940))
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        pdfWindows.removeAll { !$0.isVisible }
        pdfWindows.append(window)
    }

    // MARK: The File menu's PDF-EPUB door

    /// File ▸ PDF-EPUB… — the world's works, adopted: an Author-
    /// exported EPUB imports with its citation pool (metadata parsed
    /// and reported up front); a PDF converts to an Origami EPUB in
    /// the EPUB Library — title, author, date, journal, and cited
    /// references as best the PDF tells them — imports, and the PDF
    /// itself moves home to the Reader Library.
    func importPDFEPUB() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.epub, .pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Choose EPUBs, PDFs (each converted to an Origami EPUB on the way in, the PDF then filed in the Reader Library), or folders of either."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        // Folders unfold to the files inside them, all the way down.
        var epubs: [URL] = []
        var pdfs: [URL] = []
        for url in panel.urls {
            _ = url.startAccessingSecurityScopedResource()
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path,
                                              isDirectory: &isDirectory),
               isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(
                    at: url, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let found = enumerator?.nextObject() as? URL {
                    switch found.pathExtension.lowercased() {
                    case "pdf": pdfs.append(found)
                    case "epub": epubs.append(found)
                    default: break
                    }
                }
            } else if url.pathExtension.lowercased() == "pdf" {
                pdfs.append(url)
            } else {
                epubs.append(url)
            }
        }
        // One PDF alone converts, imports, and opens.
        if epubs.isEmpty, pdfs.count == 1, let pdf = pdfs.first {
            importPDFAsEPUB(from: pdf)
            return
        }
        // Several of anything run quietly: EPUBs import as they are,
        // PDFs convert first — no windows fly open; the shelf and the
        // library fill as the notes tell it.
        if !(epubs.count == 1 && pdfs.isEmpty) {
            for epub in epubs { importOrigamiEPUB(from: epub) }
            importPDFsAsEPUBs(pdfs)
            return
        }
        // One EPUB alone keeps the original testing door: metadata
        // parsed and reported up front, then imported and opened.
        guard let url = epubs.first else { return }
        if let metadata = OrigamiMetadata.load(fromEPUB: url) {
            if let digest = FileHasher.sha256Hex(of: url) {
                origamiMetadataByDigest[digest] = metadata
            }
            let references = metadata.references ?? [:]
            let withSources = references.values.filter { !($0.sources ?? []).isEmpty }.count
            showNote("Metadata parsed: \(references.count) references, \(withSources) with sources.")
        } else {
            showNote("No origami.json in this EPUB — citations will carry BibTeX-derived web sources only.")
        }
        importOrigamiEPUB(from: url, openWhenReady: true)
    }
}

/// The cited PDF at its cited page (1-based), in a plain PDFKit view.
private struct CitedPDFView: NSViewRepresentable {
    let url: URL
    let page: Int

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        if let document = view.document,
           page > 1, page <= document.pageCount,
           let target = document.page(at: page - 1) {
            view.go(to: target)
        }
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {}
}
