import Foundation
#if os(macOS)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

// Origami EPUBs in the library: an EPUB dropped on the shelf is read
// whole — body, concepts, references, internal citations, Map views,
// tables, images, excerpt provenance — and minted as a full document
// in the community folder, everything available to everyone syncing
// it. The EPUB itself is copied beside the document as `<id>.epub`,
// the artifact of record; re-dropping a newer export refreshes the
// document in place. Plain EPUBs import too, with what their package
// metadata gives. The mirror door, Export as EPUB, writes any document
// back out as an Origami-profile EPUB (OrigamiEPUBExport.swift).

extension AppState {

    private static let epubLibraryBookmarkKey = "epubLibraryBookmark"

    /// Grants the EPUB Library — the folder where the user's EPUBs
    /// live, the Reader Library's twin — remembered like it.
    func chooseEPUBLibrary(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        #if os(macOS)
        let data = try? url.bookmarkData(options: .withSecurityScope,
                                         includingResourceValuesForKeys: nil,
                                         relativeTo: nil)
        #else
        let data = try? url.bookmarkData()
        #endif
        UserDefaults.standard.set(data, forKey: Self.epubLibraryBookmarkKey)
        epubLibraryURL = url
    }

    /// Re-opens the granted folder at launch.
    func restoreEPUBLibrary() {
        guard let data = UserDefaults.standard.data(forKey: Self.epubLibraryBookmarkKey)
        else { return }
        var isStale = false
        #if os(macOS)
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: .withSecurityScope,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &isStale) else { return }
        #else
        guard let url = try? URL(resolvingBookmarkData: data,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &isStale) else { return }
        #endif
        _ = url.startAccessingSecurityScopedResource()
        epubLibraryURL = url
    }

    /// The document's EPUB, wherever it stands: in the EPUB Library
    /// under the readable "slug--id" name (or the id alone), or beside
    /// the document in the community folder — where imports lived
    /// before the EPUB Library existed, and still land when no folder
    /// is chosen.
    func epubCompanionURL(for doc: LiquidDoc) -> URL? {
        var candidates: [URL] = []
        if let epubLibraryURL {
            let slug = LiquidDoc.fileSlug(from: doc.title)
            if !slug.isEmpty {
                candidates.append(epubLibraryURL
                    .appendingPathComponent("\(slug)--\(doc.id).epub"))
            }
            candidates.append(epubLibraryURL
                .appendingPathComponent(doc.id).appendingPathExtension("epub"))
        }
        candidates.append(doc.fileURL.deletingLastPathComponent()
            .appendingPathComponent(doc.id).appendingPathExtension("epub"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The document an EPUB file in the EPUB Library stands for, when
    /// the pairing can be read from its name: the "slug--id" suffix a
    /// copied companion wears, the bare id, or a Visual-Meta identity
    /// key ("Title(Author-2026-…).epub").
    func pairedEPUBDocument(forFileName name: String) -> LiquidDoc? {
        let stem = (name as NSString).deletingPathExtension
        var id: String?
        if let range = stem.range(of: "--", options: .backwards) {
            id = String(stem[range.upperBound...])
        }
        let candidates = [id, stem, LiquidDoc.identityKeyID(inFileName: name)]
            .compactMap { $0.map(LiquidAddress.canonical) }
        for candidate in candidates {
            if let doc = index.allByID[candidate]?.doc { return doc }
        }
        return nil
    }

    // MARK: The cited work's doors

    /// The library document a citation record names, when the
    /// community holds the work: the record's own library address
    /// first (the `vm-id`/`origami-id` the exports inject), then its
    /// DOI, then its title against the shelved sources' own records.
    func citedDocument(for record: BibTeXRecord) -> LiquidDoc? {
        for field in ["vm-id", "origami-id"] {
            guard let raw = record.fields[field], !raw.isEmpty else { continue }
            let address = String(raw.prefix { $0 != "#" })
            if let doc = index.allByID[LiquidAddress.canonical(address)]?.doc {
                return doc
            }
        }
        let shelved = sourceEntries.compactMap { entry -> (doc: LiquidDoc, own: BibTeXRecord)? in
            entry.doc.references.first
                .flatMap { BibTeXRecord.records(in: $0.bibtex).first }
                .map { (entry.doc, $0) }
        }
        if let doi = Self.normalizedDOI(record.fields["doi"]),
           let hit = shelved.first(where: { Self.normalizedDOI($0.own.fields["doi"]) == doi }) {
            return hit.doc
        }
        if let title = Self.normalizedWorkTitle(record.title),
           let hit = shelved.first(where: { Self.normalizedWorkTitle($0.own.title) == title }) {
            return hit.doc
        }
        return nil
    }

    /// A DOI as its bare comparable form: the resolver prefixes and
    /// the "doi:" label dropped, case folded.
    private static func normalizedDOI(_ raw: String?) -> String? {
        guard var doi = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !doi.isEmpty else { return nil }
        for prefix in ["https://doi.org/", "http://doi.org/", "https://dx.doi.org/",
                       "http://dx.doi.org/", "doi:"] where doi.hasPrefix(prefix) {
            doi = String(doi.dropFirst(prefix.count))
        }
        return doi.isEmpty ? nil : doi
    }

    /// A title as its comparable form: letters and digits only, case
    /// folded — punctuation and spacing differences between two
    /// records of one work never block the match.
    private static func normalizedWorkTitle(_ raw: String) -> String? {
        let core = raw.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
        return core.isEmpty ? nil : String(String.UnicodeScalarView(core))
    }

    /// Whether Open on a clicked citation has somewhere to go — the
    /// shelf, the Reader Library, or the web.
    func canOpenCitedWork(_ record: BibTeXRecord) -> Bool {
        citedDocument(for: record) != nil || record.webURL != nil
    }

    /// Open on a clicked citation, nearest copy first: a work the
    /// library holds whole — an imported EPUB's document, or any
    /// document the record addresses — opens right here; a source
    /// standing for a PDF hands its file to the Mac's PDF app
    /// (Reader); with nothing on the shelf, the record's DOI or web
    /// page opens in the browser.
    func openCitedWork(_ record: BibTeXRecord) {
        if let doc = citedDocument(for: record) {
            #if os(macOS)
            if let pdf = sourcePDFURL(for: doc) {
                NSWorkspace.shared.open(pdf)
                return
            }
            #endif
            openInLibrary(doc)
            return
        }
        guard let url = record.webURL else {
            showNote("The library does not hold this work, and its record names no DOI or web page.")
            return
        }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    /// The work's abstract, when anyone recorded one: the citation's
    /// own BibTeX field first, else the Abstract section of the
    /// shelved source (the Reader Library harvest writes one).
    func citedWorkAbstract(of record: BibTeXRecord) -> String? {
        if let own = record.fields["abstract"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !own.isEmpty {
            return own
        }
        guard let body = citedDocument(for: record)?.body,
              let heading = body.firstIndex(where: {
                  $0.heading != nil && $0.text.trimmingCharacters(in: .whitespaces)
                      .caseInsensitiveCompare("Abstract") == .orderedSame
              }),
              heading + 1 < body.count else { return nil }
        let text = body[heading + 1].text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Imports an EPUB into the community folder: the parsed document
    /// minted whole, the EPUB copied beside it. A document already
    /// shelved under the same address refreshes — its text and pools
    /// follow the new export; its filing, standing, and shelving stay.
    /// The parse and the writes run off the main actor — a chaptered
    /// book is a real read.
    func importOrigamiEPUB(from url: URL, openWhenReady: Bool = false) {
        guard index.folderURL != nil else {
            showNote("Choose a community folder first — books live there.")
            return
        }
        _ = url.startAccessingSecurityScopedResource()
        showNote("Reading “\(url.lastPathComponent)”…")
        Task.detached(priority: .userInitiated) {
            do {
                let result = try OrigamiEPUBImporter.importDocument(at: url)
                await MainActor.run {
                    self.adoptEPUBImport(result, from: url, openWhenReady: openWhenReady)
                }
            } catch {
                await MainActor.run {
                    self.showNote("Couldn’t read “\(url.lastPathComponent)”: \(error.localizedDescription)")
                }
            }
        }
    }

    /// The parsed EPUB onto the shelf: address settled, document minted
    /// or refreshed, then written — and the EPUB copied beside it —
    /// off the main actor.
    private func adoptEPUBImport(_ result: OrigamiEPUBImporter.ImportResult,
                                 from url: URL, openWhenReady: Bool = false) {
        guard let folderURL = index.folderURL else { return }

        // The address: the EPUB's own origami address when it carries
        // one — citations to the work resolve wherever it arrives —
        // else the identity key its file name may carry, else minted.
        let carried = result.origamiID.map(LiquidAddress.canonical)
            .flatMap { LiquidAddress.isValid($0) ? $0 : nil }
        let docID = carried
            ?? LiquidDoc.identityKeyID(inFileName: url.lastPathComponent)
            ?? LiquidAddress.makeID(author: authorName) { self.index.isIDTaken($0) }

        var body = result.body
        if body.isEmpty {
            body = [LiquidDoc.Paragraph(id: "p1", heading: nil,
                                        text: "Imported from \(url.lastPathComponent) — the EPUB carried no readable body.")]
        }

        // The work's own record leads the reference list, like a PDF
        // source's self-citation, so the Library shelves it.
        let selfRecord = Self.selfBibTeX(id: docID,
                                         title: result.title,
                                         author: result.author,
                                         date: result.date)

        let existing = index.allByID[docID]?.doc
        var doc: LiquidDoc
        if var known = existing {
            // A newer export of a shelved work: the words and pools
            // follow it; the reader's own arrangements stay.
            known.title = result.title
            known.body = body
            known.links = result.links
            known.concepts = result.concepts
            known.layouts = result.layouts
            known.mapConnections = result.mapConnections
            known.tables = result.tables
            known.assets = result.assets
            known.excerptOf = result.excerptOf
            if let date = result.date.flatMap(LiquidDate.init(isoString:)) {
                known.date = date
            }
            // The user's word on the work's kind stands: a reshelved
            // record keeps its entry type; only the tail refreshes.
            let head = known.references.first(where: { $0.id == docID })
                ?? LiquidDoc.Reference(id: docID, bibtex: selfRecord)
            known.references = [head] + result.references.filter { $0.id != docID }
            doc = known
        } else {
            doc = LiquidDoc(
                format: LiquidDoc.knownFormat,
                id: docID,
                title: result.title,
                author: result.author ?? "Unknown",
                created: .now,
                body: body,
                links: result.links,
                wraps: nil,
                date: result.date.flatMap(LiquidDate.init(isoString:)),
                documentType: LiquidDoc.DocumentType.source.rawValue,
                concepts: result.concepts,
                layouts: result.layouts,
                mapConnections: result.mapConnections,
                references: [LiquidDoc.Reference(id: docID, bibtex: selfRecord)]
                    + result.references.filter { $0.id != docID },
                tables: result.tables,
                assets: result.assets,
                fileURL: folderURL.appendingPathComponent(docID)
                    .appendingPathExtension(LiquidDoc.fileExtension))
            doc.excerptOf = result.excerptOf
        }

        // Where the EPUB itself goes: the EPUB Library when one is
        // chosen — under a readable "slug--id" name, so the file and
        // its record pair by eye and by machine — else beside the
        // document in the community folder, as before the EPUB
        // Library existed.
        let slug = LiquidDoc.fileSlug(from: doc.title)
        let companion: URL
        if let epubLibraryURL {
            companion = epubLibraryURL.appendingPathComponent(
                slug.isEmpty ? "\(doc.id).epub" : "\(slug)--\(doc.id).epub")
        } else {
            companion = doc.fileURL.deletingLastPathComponent()
                .appendingPathComponent(doc.id).appendingPathExtension("epub")
        }
        // A file already living in the EPUB Library is its own copy —
        // the user's file stands; nothing is duplicated beside it.
        let sourceInLibrary = epubLibraryURL.map {
            url.deletingLastPathComponent().path == $0.path
        } ?? false

        // The serialization, the write, and the EPUB copy are the heavy
        // part — off the main actor; the shelf refreshes when they land.
        let minted = doc
        let isNew = existing == nil
        let title = result.title
        Task.detached(priority: .userInitiated) {
            do {
                try minted.jsonData().write(to: minted.fileURL, options: .atomic)
            } catch {
                await MainActor.run {
                    self.showNote("Couldn’t write “\(title)”: \(error.localizedDescription)")
                }
                return
            }
            if !sourceInLibrary,
               FileHasher.sha256Hex(of: url) != FileHasher.sha256Hex(of: companion) {
                try? FileManager.default.removeItem(at: companion)
                try? FileManager.default.copyItem(at: url, to: companion)
            }
            await MainActor.run {
                self.index.rescan()
                self.showNote(isNew
                    ? "“\(title)” joined the shelf, text and all."
                    : "“\(title)” refreshed from the new export.")
                // A Finder-opened book reads at once, in its own window.
                if openWhenReady {
                    self.pendingReaderDocID = minted.id
                }
            }
        }
    }

    /// The work's own BibTeX: a @book entry under the document's
    /// address — the Books shelf's word for an EPUB — with the year
    /// where the package named one.
    private static func selfBibTeX(id: String, title: String,
                                   author: String?, date: String?) -> String {
        func escaped(_ value: String) -> String {
            value.replacingOccurrences(of: "{", with: "(")
                .replacingOccurrences(of: "}", with: ")")
        }
        var fields = ["  title = {\(escaped(title.isEmpty ? "Untitled" : title))}"]
        if let author, !author.isEmpty {
            fields.append("  author = {\(escaped(author))}")
        }
        if let year = date?.prefix(4), year.count == 4, Int(year) != nil {
            fields.append("  year = {\(year)}")
        }
        return "@book{\(id),\n" + fields.joined(separator: ",\n") + ",\n}"
    }

    /// A section carved out as a document of its own, into the
    /// community folder: the heading and everything under it, the
    /// reference, table, image, and glossary pools trimmed to what the
    /// section uses, `excerptOf` naming the original — so citations
    /// made from the excerpt address the original document. The id is
    /// deterministic; carving the same section twice is the same
    /// document, refreshed.
    func excerptSection(of doc: LiquidDoc, headingID: String) {
        guard let folderURL = index.folderURL else {
            showNote("Choose a community folder first — excerpts live there.")
            return
        }
        guard var excerpt = OrigamiReading.excerpt(of: doc, headingID: headingID) else {
            showNote("That section could not be carved out.")
            return
        }
        // A re-carve refreshes the same address; the first carve keeps
        // its own created moment.
        if let known = index.allByID[excerpt.id]?.doc {
            excerpt.created = known.created
            excerpt.fileURL = known.fileURL
        } else {
            excerpt.fileURL = folderURL.appendingPathComponent(excerpt.id)
                .appendingPathExtension(LiquidDoc.fileExtension)
        }
        do {
            try excerpt.jsonData().write(to: excerpt.fileURL, options: .atomic)
            index.rescan()
            openInLibrary(excerpt)
            showNote("“\(excerpt.title)” carved out as its own document — citations from it address the original.")
        } catch {
            showNote("Couldn’t write the excerpt: \(error.localizedDescription)")
        }
    }

    #if os(macOS)
    /// Opens an Interatlas link where the reader said to. The URL
    /// carries the whole scene; the question is only which door the
    /// app offers. In order: the `interatlas://` scheme once Interatlas
    /// declares one; the chosen app (Settings ▸ Library) handed the
    /// https link; and when the app declares no way to receive a URL
    /// at all — today's Interatlas — the link goes to the clipboard
    /// and the app comes forward, rather than a dead system alert.
    func openInteratlasLink(_ url: URL) {
        openSceneLink(url, schemedForms: [InteratlasLink.schemed(url)].compactMap { $0 },
                      appPath: interatlasAppPath,
                      cantReceiveNote: "Interatlas can’t receive links yet — the scene link is on the clipboard, ready to paste there. INTERATLAS-URL-SCHEME.md carries the one-entry fix.")
    }

    /// Opens a Liquid view link — Author's 3D view citation on the
    /// same link domain, path /liquid/ — by the same ladder, through
    /// Liquid's own doors (`liquidinfo://`, the old `liquid://`, or
    /// the chosen app).
    func openLiquidViewLink(_ url: URL) {
        openSceneLink(url, schemedForms: LiquidViewLink.schemedForms(url),
                      appPath: liquidAppPath,
                      cantReceiveNote: "That app can’t receive links yet — the view link is on the clipboard, ready to paste there.")
    }

    /// Hands a complete scene to Liquid Information as a `.liquidinfo`
    /// file — the road for scenes too large to ride in any URL
    /// (SCENE-DATA-IN-EPUB.md). The doors, in order: the chosen app
    /// (Settings ▸ Library), whatever app is registered for the file
    /// type, and failing both, the file revealed in the Finder with
    /// the truth on the status line — never a click that does nothing.
    func openLiquidScene(json: String, link: URL) {
        let name = link.pathComponents.last.flatMap { $0.isEmpty ? nil : $0 } ?? "scene"
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(name)
            .appendingPathExtension("liquidinfo")
        do {
            try Data(json.utf8).write(to: fileURL, options: .atomic)
        } catch {
            showNote("Couldn’t write the scene file: \(error.localizedDescription)")
            return
        }
        func reveal() {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            showNote("The scene is too large for a link — it is written as \(fileURL.lastPathComponent) and revealed in the Finder, ready to open in Liquid Information. LIQUID-OPEN-SOURCE-HANDOFF.md carries the document-type fix.")
        }
        if let liquidAppPath, FileManager.default.fileExists(atPath: liquidAppPath) {
            NSWorkspace.shared.open([fileURL],
                                    withApplicationAt: URL(fileURLWithPath: liquidAppPath),
                                    configuration: NSWorkspace.OpenConfiguration()) { _, error in
                guard error != nil else { return }
                Task { @MainActor in reveal() }
            }
            return
        }
        if NSWorkspace.shared.urlForApplication(toOpen: fileURL) != nil,
           NSWorkspace.shared.open(fileURL) {
            return
        }
        reveal()
    }

    /// The one ladder every scene-link kind climbs. The chosen app
    /// (Settings ▸ Library) always wins: an explicit choice outranks
    /// whatever app happens to have claimed a scheme — stale archive
    /// builds do, and Launch Services remembers them. Only without a
    /// choice do the schemes' registered handlers get the link, newest
    /// scheme first, and failing those the browser.
    private func openSceneLink(_ url: URL, schemedForms: [URL], appPath: String?,
                               cantReceiveNote: String) {
        if let appPath, FileManager.default.fileExists(atPath: appPath) {
            openSceneLink(url, schemedForms: schemedForms,
                          withApplicationAt: URL(fileURLWithPath: appPath),
                          cantReceiveNote: cantReceiveNote)
            return
        }
        // Every rung answers or the ladder climbs on: a scheme whose
        // registered app has moved or been deleted (a stale Launch
        // Services memory) fails in silence unless the result is
        // checked.
        for schemed in schemedForms
        where NSWorkspace.shared.urlForApplication(toOpen: schemed) != nil {
            if NSWorkspace.shared.open(schemed) { return }
        }
        if NSWorkspace.shared.open(url) { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        showNote("The link couldn\u{2019}t be opened here — it is on the clipboard, ready to paste.")
    }

    /// The chosen app's own doors, in order: whichever scheme form the
    /// app claims; the https link when Launch Services agrees the app
    /// can take it — a forced hand-off the app never declared makes
    /// macOS itself throw the "cannot open" alert, before any
    /// completion handler hears of it; and failing both, the link to
    /// the clipboard and the app to the front, with the truth on the
    /// status line.
    private func openSceneLink(_ url: URL, schemedForms: [URL],
                               withApplicationAt appURL: URL,
                               cantReceiveNote: String) {
        let appPath = appURL.standardizedFileURL.path
        func claims(_ candidate: URL) -> Bool {
            NSWorkspace.shared.urlsForApplications(toOpen: candidate)
                .contains { $0.standardizedFileURL.path == appPath }
        }
        // The last resort, shared by every failed hand-off: the link
        // onto the clipboard, the app to the front, and the truth on
        // the status line — never a click that does nothing.
        func fallBack() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
            NSWorkspace.shared.openApplication(at: appURL,
                                               configuration: NSWorkspace.OpenConfiguration())
            showNote(cantReceiveNote)
        }
        // A hand-off's failure arrives in its completion, off the main
        // thread and easy to lose — heard here, it falls back visibly.
        func hand(_ links: [URL]) {
            NSWorkspace.shared.open(links, withApplicationAt: appURL,
                                    configuration: NSWorkspace.OpenConfiguration()) { _, error in
                guard error != nil else { return }
                Task { @MainActor in fallBack() }
            }
        }
        for schemed in schemedForms where claims(schemed) {
            hand([schemed])
            return
        }
        if claims(url) {
            hand([url])
            return
        }
        fallBack()
    }

    /// Files arriving from File ▸ Open…, the Finder, or the Dock icon,
    /// routed by kind: an EPUB imports whole — the EPUB shelf opens to
    /// show it landing — and an email becomes a document.
    func openFiles(_ urls: [URL]) {
        let epubs = urls.filter { $0.pathExtension.lowercased() == "epub" }
        for epub in epubs {
            // Opened means read: the book takes a window of its own
            // the moment its import lands.
            importOrigamiEPUB(from: epub, openWhenReady: true)
        }
        if !epubs.isEmpty {
            sidebarSelection = .epubShelf(.alphabetical)
        }
        let rest = urls.filter { $0.pathExtension.lowercased() != "epub" }
        if !rest.isEmpty {
            handleEmailFiles(rest)
        }
    }

    /// Any document out as an Origami-profile EPUB, via the save
    /// panel — the mirror of the import, written by the ported
    /// exporter so the file opens identically in Origami Text and
    /// Augmented Library.
    func exportOrigamiEPUB(_ doc: LiquidDoc) {
        guard doc.body != nil else {
            showNote("“\(doc.title)” wraps a file rather than carrying text — there is nothing to write as an EPUB.")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = doc.identityFileName(extension: "epub")
        panel.message = "Write “\(doc.title)” as an Origami-profile EPUB — a valid EPUB anywhere, whole to any Origami reader."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try OrigamiEPUBExporter.write(doc, to: url,
                                          generator: "Knowledge Space (macOS)")
            showNote("“\(doc.title)” written as \(url.lastPathComponent).")
        } catch {
            showNote("Couldn’t write the EPUB: \(error.localizedDescription)")
        }
    }
    #endif
}
