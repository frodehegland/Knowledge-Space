#if os(macOS)
import Foundation
import AppKit
import QuickLookThumbnailing

// The Author library: the folder where Author keeps its .liquid
// documents — the iCloud Author folder unless another is chosen —
// read in place so the library can list Author's work by time,
// keyword, and name. Each document is a package; Knowledge Space
// reads its Contents (Author.plist, Content.rtfd, glossary.json,
// Citations.plist) and never writes a byte back. The documents
// open in Author, where they live.

// MARK: - One Author document, read

/// Everything the library reads out of one Author .liquid document.
/// The file name is the document's name — that is what Author shows —
/// while Author.plist's title is the publishing title, kept as
/// metadata where it differs.
nonisolated struct AuthorDocument: Identifiable, Codable, Sendable {
    /// The package's full path — the identity, and the way back to it.
    let path: String
    /// The publishing title from Author.plist, often empty or stale.
    let publishingTitle: String
    /// The writer, from Author.plist — "First Middle Last".
    let authorName: String
    let institution: String
    let course: String
    let module: String
    /// Filesystem dates: when the document began, when it last changed.
    let created: Date
    let modified: Date
    /// The glossary's phrases — Author's own terms for what the
    /// document is about. These are the library's keywords.
    let keywords: [String]
    /// Everyone the document cites, "First Last", each once.
    let citedNames: [String]
    let wordCount: Int
    /// The document's opening words, for the list row.
    let preview: String
    /// The body's plain text, capped, for search and the detail page.
    let text: String
    /// False for the old flat-file Author format, which is listed by
    /// name and date alone.
    let isPackage: Bool
    /// The newest inner modification stamp seen at scan time — the
    /// cache's freshness test.
    let stamp: TimeInterval

    var id: String { path }
    var fileURL: URL { URL(fileURLWithPath: path) }
    /// The document's name as Author shows it: the file's own.
    var displayTitle: String {
        fileURL.deletingPathExtension().lastPathComponent
    }
}

// MARK: - The document's own icon

/// The icon Author now writes with each saved document: the package's
/// `QuickLook/Preview.pdf` — the classic document-package preview
/// convention. The icon shown is the system's own **icon-view**
/// rendering of the document (QLThumbnailGenerator's `.icon`
/// representation — the decorated face the Finder's icon view draws),
/// never the small generic list-view file icon: a document whose
/// package carries no preview answers nil and shows nothing. Icons
/// are cached against the preview's modification stamp, so a re-save
/// in Author shows its new face without a rescan.
@MainActor
enum AuthorDocumentIcon {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        return cache
    }()

    /// Whether Author wrote an icon with this document at all — only
    /// then is the system asked for one.
    static func hasIcon(_ document: AuthorDocument) -> Bool {
        previewStamp(of: document) != nil
    }

    static func icon(for document: AuthorDocument, height: CGFloat) async -> NSImage? {
        guard let stamp = previewStamp(of: document) else { return nil }
        let key = "\(document.path)|\(stamp)|\(Int(height))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        // The content thumbnail in icon mode is the Finder icon-view
        // face; the `.icon` representation would be the generic
        // file-type badge — the list-view icon — which must never
        // stand in. A document whose thumbnail cannot be generated
        // shows nothing.
        let request = QLThumbnailGenerator.Request(
            fileAt: document.fileURL,
            size: CGSize(width: height, height: height),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail)
        request.iconMode = true
        guard let representation = try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request) else { return nil }
        let image = representation.nsImage
        cache.setObject(image, forKey: key)
        return image
    }

    private static func previewStamp(of document: AuthorDocument) -> TimeInterval? {
        let preview = document.fileURL.appendingPathComponent("QuickLook/Preview.pdf")
        let modified = (try? FileManager.default
            .attributesOfItem(atPath: preview.path))?[.modificationDate] as? Date
        return modified?.timeIntervalSinceReferenceDate
    }
}

// MARK: - Reading the folder

nonisolated enum AuthorLibraryScanner {

    /// Author's iCloud documents folder — where the documents are
    /// unless Settings says otherwise. The real home, not the
    /// sandbox's container: the folder is read once the user grants
    /// it, and the choose panel starts here.
    static var defaultFolder: URL {
        let home: URL
        if let record = getpwuid(getuid()), let dir = record.pointee.pw_dir {
            home = URL(fileURLWithPath: String(cString: dir))
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
        }
        return home
            .appendingPathComponent("Library/Mobile Documents/iCloud~com~liquid~Author/Documents")
    }

    /// How much plain text each document keeps aboard for search and
    /// the detail page's preview.
    static let textCap = 12_000

    /// Walks the folder for .liquid documents, reading each package's
    /// Contents. A document unchanged since the last scan comes from
    /// the cache without a read.
    static func scan(folder: URL,
                     cached: [String: AuthorDocument]) async -> [AuthorDocument] {
        let fm = FileManager.default
        var found: [(url: URL, isPackage: Bool)] = []
        let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "liquid" else { continue }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory ?? false
            found.append((url, isDirectory))
            // A package is opaque to the walk — nothing inside it is a
            // document of its own.
            if isDirectory { enumerator?.skipDescendants() }
        }
        let work = found
        return await withTaskGroup(of: AuthorDocument?.self) { group in
            for item in work {
                group.addTask {
                    read(at: item.url, isPackage: item.isPackage, cached: cached)
                }
            }
            var documents: [AuthorDocument] = []
            for await document in group {
                if let document { documents.append(document) }
            }
            return documents.sorted { $0.created > $1.created }
        }
    }

    /// One document, from the cache when nothing inside it has
    /// changed, from its files otherwise.
    private static func read(at url: URL, isPackage: Bool,
                             cached: [String: AuthorDocument]) -> AuthorDocument? {
        let stamp = freshnessStamp(of: url, isPackage: isPackage)
        if let known = cached[url.path], known.stamp == stamp {
            return known
        }
        let attributes = try? FileManager.default
            .attributesOfItem(atPath: url.path)
        let created = attributes?[.creationDate] as? Date
            ?? attributes?[.modificationDate] as? Date ?? .distantPast
        let modified = attributes?[.modificationDate] as? Date ?? created
        guard isPackage else {
            // The old flat-file format: listed by name and date, opened
            // in Author like the rest.
            return AuthorDocument(path: url.path, publishingTitle: "",
                                  authorName: "", institution: "", course: "",
                                  module: "", created: created, modified: modified,
                                  keywords: [], citedNames: [], wordCount: 0,
                                  preview: "", text: "", isPackage: false,
                                  stamp: stamp)
        }
        let contents = url.appendingPathComponent("Contents")
        let plist = dictionary(atPlist: contents.appendingPathComponent("Author.plist"))
        let authorName = [plist["firstName"], plist["middleName"], plist["lastName"]]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let text = plainText(inRTFDAt: contents.appendingPathComponent("Content.rtfd"))
        let words = text.split(whereSeparator: \.isWhitespace)
        return AuthorDocument(
            path: url.path,
            publishingTitle: (plist["title"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            authorName: authorName,
            institution: plist["institution"] as? String ?? "",
            course: plist["course"] as? String ?? "",
            module: plist["module"] as? String ?? "",
            created: created,
            modified: modified,
            keywords: glossaryPhrases(atJSON: contents.appendingPathComponent("glossary.json")),
            citedNames: citedNames(atPlist: contents.appendingPathComponent("Citations.plist")),
            wordCount: words.count,
            preview: words.prefix(40).joined(separator: " "),
            text: String(text.prefix(textCap)),
            isPackage: true,
            stamp: stamp)
    }

    /// The newest modification among the pieces Author rewrites on
    /// save. Editing changes files inside Contents, not always the
    /// package folder itself, so the stamp looks inside.
    private static func freshnessStamp(of url: URL, isPackage: Bool) -> TimeInterval {
        let fm = FileManager.default
        var candidates = [url]
        if isPackage {
            let contents = url.appendingPathComponent("Contents")
            candidates.append(contents)
            candidates.append(contents.appendingPathComponent("Content.rtfd/TXT.rtf"))
            candidates.append(contents.appendingPathComponent("Author.plist"))
        }
        return candidates.compactMap {
            (try? fm.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
        }
        .map(\.timeIntervalSinceReferenceDate)
        .max() ?? 0
    }

    private static func dictionary(atPlist url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data,
                                                                      format: nil)
        else { return [:] }
        return plist as? [String: Any] ?? [:]
    }

    /// The document's words, read from the RTF Author keeps beside its
    /// store. An evicted iCloud file reads as empty — the document
    /// still lists by name and date, and opening it in Author brings
    /// it down.
    private static func plainText(inRTFDAt url: URL) -> String {
        let rtf = url.appendingPathComponent("TXT.rtf")
        guard let data = try? Data(contentsOf: rtf),
              let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil)
        else { return "" }
        return attributed.string
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func glossaryPhrases(atJSON url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["entries"] as? [String: [String: Any]]
        else { return [] }
        var seen = Set<String>()
        var phrases: [String] = []
        for entry in entries.values {
            guard let phrase = (entry["phrase"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !phrase.isEmpty,
                  seen.insert(phrase.lowercased()).inserted else { continue }
            phrases.append(phrase)
        }
        return phrases.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func citedNames(atPlist url: URL) -> [String] {
        let citations = dictionary(atPlist: url)
        var seen = Set<String>()
        var names: [String] = []
        for value in citations.values {
            guard let citation = value as? [String: Any],
                  let authors = citation["citationAuthors"] as? [[String: Any]]
            else { continue }
            for author in authors {
                let name = [author["firstName"], author["lastName"]]
                    .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
                names.append(name)
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: The cache

    /// Where the scan's read lives between runs — plain JSON, one
    /// entry per document, refreshed when a document changes.
    static var cacheURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
            .appendingPathComponent("Knowledge Space", isDirectory: true)
        try? FileManager.default.createDirectory(at: support,
                                                 withIntermediateDirectories: true)
        return support.appendingPathComponent("AuthorLibrary.json")
    }

    static func loadCache() -> [String: AuthorDocument] {
        guard let data = try? Data(contentsOf: cacheURL),
              let documents = try? JSONDecoder().decode([AuthorDocument].self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: documents.map { ($0.path, $0) })
    }

    static func saveCache(_ documents: [AuthorDocument]) {
        guard let data = try? JSONEncoder().encode(documents) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}

// MARK: - The Author library on AppState

extension AppState {

    private static let authorFolderBookmarkKey = "authorLibraryBookmark"

    /// The folder the scan walks: the chosen one, else Author's own
    /// iCloud folder.
    var effectiveAuthorFolderURL: URL {
        authorLibraryURL ?? AuthorLibraryScanner.defaultFolder
    }

    /// Chooses a different Author folder — remembered like the Reader
    /// Library — and scans it at once.
    func chooseAuthorLibrary(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        let data = try? url.bookmarkData(options: .withSecurityScope,
                                         includingResourceValuesForKeys: nil,
                                         relativeTo: nil)
        UserDefaults.standard.set(data, forKey: Self.authorFolderBookmarkKey)
        authorLibraryURL = url
        scanAuthorLibrary()
    }

    /// Re-opens a chosen folder at launch; the default folder needs no
    /// remembering.
    func restoreAuthorLibrary() {
        guard let data = UserDefaults.standard.data(forKey: Self.authorFolderBookmarkKey)
        else { return }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: .withSecurityScope,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &isStale) else { return }
        _ = url.startAccessingSecurityScopedResource()
        authorLibraryURL = url
    }

    /// The quiet first scan, run when the Author section first shows —
    /// cached documents return in a blink; only changes are read.
    func authorLibraryUpkeep() {
        guard !authorScanDone else { return }
        authorScanDone = true
        scanAuthorLibrary(quiet: true)
    }

    /// Whether the Author folder can be read as things stand — the
    /// sandbox needs the folder granted once before the default
    /// folder answers.
    var authorFolderIsReadable: Bool {
        FileManager.default.isReadableFile(atPath: effectiveAuthorFolderURL.path)
    }

    /// Walks the Author folder, reading every .liquid document in
    /// place. The documents are read, never touched.
    func scanAuthorLibrary(quiet: Bool = false) {
        guard !authorScanRunning else { return }
        let folder = effectiveAuthorFolderURL
        guard FileManager.default.isReadableFile(atPath: folder.path) else {
            if !quiet {
                showNote("Grant the Author folder first — Settings ▸ Library, or the Author section's own Choose button.")
            }
            return
        }
        authorScanRunning = true
        Task.detached(priority: .utility) {
            let cached = AuthorLibraryScanner.loadCache()
            let documents = await AuthorLibraryScanner.scan(folder: folder, cached: cached)
            AuthorLibraryScanner.saveCache(documents)
            await MainActor.run {
                self.authorDocuments = documents
                self.authorScanRunning = false
                if !quiet {
                    self.showNote(documents.isEmpty
                        ? "No Author documents found in \(folder.lastPathComponent)."
                        : "\(documents.count) Author documents on the shelf.")
                }
            }
        }
    }

    /// Hands the document to Author itself — the same door the Finder
    /// uses. An evicted iCloud document is asked down first.
    func openInAuthor(_ document: AuthorDocument) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: document.fileURL)
        NSWorkspace.shared.open(document.fileURL)
    }
}
#endif
