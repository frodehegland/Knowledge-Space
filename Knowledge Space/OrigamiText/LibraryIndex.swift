import Foundation
import Observation

nonisolated struct IndexEntry: Identifiable, Hashable, Sendable {
    let doc: LiquidDoc
    var hasDuplicate = false
    var id: String { doc.id }
}

nonisolated struct BacklinkRef: Hashable, Sendable {
    let fromID: String
    let rel: String?
    let fragment: String?
}

nonisolated struct UnreadableFile: Identifiable, Hashable, Sendable {
    let fileURL: URL
    let reason: String
    var id: URL { fileURL }
}

/// The community-folder index: id lookup, backlinks, revision chains, and a
/// created-date timeline. Scans on a background task, publishes on the main actor.
@MainActor @Observable
final class LibraryIndex {
    private(set) var folderURL: URL?
    /// The library as the lists and views see it — documents filed
    /// under Archived are left out, the folder being a trash can.
    private(set) var byID: [String: IndexEntry] = [:]
    /// Everything scanned, Archived included — the Archived list's way
    /// in, and the reader's, so a note can be retrieved.
    private(set) var allByID: [String: IndexEntry] = [:]
    private(set) var backlinks: [String: [BacklinkRef]] = [:]
    /// Card id → the notes whose words name that card's person, newest
    /// first — recomputed with every scan, so it is fresh at launch and
    /// follows edits and arriving cards. Archived stays out of both
    /// sides.
    private(set) var mentions: [String: [String]] = [:]
    /// Keyed by the superseded (older) document; the value is the newer
    /// document whose `revises` link points at it.
    private(set) var revisionOf: [String: String] = [:]
    private(set) var timeline: [IndexEntry] = []
    private(set) var unreadableFiles: [UnreadableFile] = []
    private(set) var supersededIDs: Set<String> = []
    /// Documents targeted by a `retracts` link: withdrawn by their author.
    private(set) var retractedIDs: Set<String> = []
    private(set) var isScanning = false

    /// Documents filed under Archived, told to the index by AppState —
    /// the filing lives in preferences, not in the files.
    private var archivedIDs: Set<String> = []
    private var fullBacklinks: [String: [BacklinkRef]] = [:]
    private var fullTimeline: [IndexEntry] = []
    private var fullMentions: [String: [String]] = [:]

    // FSEvents watching is macOS-only; visionOS rescans on demand and on
    // scene activation instead.
    #if os(macOS)
    private var watcher: FolderWatcher?
    #endif
    private var scanGeneration = 0

    /// Archived is a trash can: its documents leave byID, backlinks,
    /// and the timeline, so no list or view sees them until unfiled.
    func setArchivedIDs(_ ids: Set<String>) {
        guard ids != archivedIDs else { return }
        archivedIDs = ids
        applyArchiveFilter()
    }

    private func applyArchiveFilter() {
        guard !archivedIDs.isEmpty else {
            byID = allByID
            backlinks = fullBacklinks
            timeline = fullTimeline
            mentions = fullMentions
            return
        }
        byID = allByID.filter { !archivedIDs.contains($0.key) }
        timeline = fullTimeline.filter { !archivedIDs.contains($0.id) }
        var filtered: [String: [BacklinkRef]] = [:]
        for (target, refs) in fullBacklinks where !archivedIDs.contains(target) {
            let kept = refs.filter { !archivedIDs.contains($0.fromID) }
            if !kept.isEmpty { filtered[target] = kept }
        }
        backlinks = filtered
        var filteredMentions: [String: [String]] = [:]
        for (cardID, noteIDs) in fullMentions where !archivedIDs.contains(cardID) {
            let kept = noteIDs.filter { !archivedIDs.contains($0) }
            if !kept.isEmpty { filteredMentions[cardID] = kept }
        }
        mentions = filteredMentions
    }

    /// Places a freshly-created document into the index at once, so the
    /// editor and lists can resolve it before the next background scan
    /// lands — a new note opens into writing instantly rather than after
    /// a full rescan. The scan then reconciles; this only bridges the gap.
    func insert(_ doc: LiquidDoc) {
        let entry = IndexEntry(doc: doc)
        allByID[doc.id] = entry
        // The timeline sorts ascending by listed date, so a new note —
        // the latest — belongs at the end.
        fullTimeline.append(entry)
        applyArchiveFilter()
    }

    /// Replaces a document already in the index with an edited copy, at
    /// once — so a metadata change made in the reader's column (a
    /// standing set, a note filed, Important toggled) shows the instant
    /// it is written, rather than after the next background scan of the
    /// whole folder. The scan then reconciles (backlinks, duplicates,
    /// timeline order); this only bridges the gap. A document the index
    /// has not seen yet is inserted.
    func update(_ doc: LiquidDoc) {
        guard allByID[doc.id] != nil else { insert(doc); return }
        let entry = IndexEntry(doc: doc)
        allByID[doc.id] = entry
        if let position = fullTimeline.firstIndex(where: { $0.id == doc.id }) {
            fullTimeline[position] = entry
        }
        applyArchiveFilter()
    }

    func setFolder(_ url: URL) {
        folderURL = url
        #if os(macOS)
        watcher?.stop()
        watcher = FolderWatcher(url: url) { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.rescan() }
        }
        #endif
        rescan()
    }

    func rescan() {
        guard let folderURL else { return }
        scanGeneration += 1
        let generation = scanGeneration
        isScanning = true
        Task.detached(priority: .userInitiated) {
            // Two passes. The first reads and decodes the folder — in
            // parallel across cores — and publishes everything the lists
            // and reader need (ids, backlinks, revisions, the timeline),
            // so the library appears as soon as the files are in. The
            // second computes person mentions, a whole-folder text scan
            // that powers only the per-person "mentioned in" lists; it
            // used to run before anything was shown, holding the whole
            // library behind the slowest part.
            let core = await LibraryScanner.scanCore(folder: folderURL)
            await MainActor.run {
                guard generation == self.scanGeneration else { return }
                self.allByID = core.byID
                self.fullBacklinks = core.backlinks
                self.fullTimeline = core.timeline
                self.revisionOf = core.revisionOf
                self.unreadableFiles = core.unreadable
                self.supersededIDs = Set(core.revisionOf.keys)
                self.retractedIDs = core.retractedIDs
                // Leave the previous scan's mentions in place until the
                // second pass replaces them, so nothing flickers to empty.
                self.applyArchiveFilter()
                self.isScanning = false
            }

            let mentions = LibraryScanner.mentions(in: core.timeline, folder: folderURL)
            await MainActor.run {
                // A newer scan may have started (and finished) while this
                // one computed mentions — its results win.
                guard generation == self.scanGeneration else { return }
                self.fullMentions = mentions
                self.applyArchiveFilter()
            }
        }
    }

    /// Whether a candidate document id is already spoken for — by any
    /// indexed document (Archived included) or by an id-named file the
    /// scanner has not read yet. The writer's side of collision honesty:
    /// nobody may emit an id that collides knowingly, and the reach is
    /// everything this library can see, not just what its lists show.
    func isIDTaken(_ candidate: String) -> Bool {
        if allByID[candidate] != nil { return true }
        guard let folderURL else { return false }
        return FileManager.default.fileExists(
            atPath: folderURL.appendingPathComponent(candidate)
                .appendingPathExtension(LiquidDoc.fileExtension).path)
    }

    /// Follows `revises` chains forward to the newest revision.
    /// On a cycle, returns the input unchanged.
    func latestRevision(of id: String) -> String {
        var visited: Set<String> = [id]
        var current = id
        while let newer = revisionOf[current] {
            guard !visited.contains(newer) else { return id }
            visited.insert(newer)
            current = newer
        }
        return current
    }
}

/// Folder conventions shared across the apps' library scans.
nonisolated enum KnowledgeSpaceFolders {
    /// The subfolder external `source` sidecars (one JSON per external PDF)
    /// are kept in, so the routine library scan — and its iCloud download
    /// requests — do not have to walk the many hundreds of them. The scan
    /// does not descend into it; files inside are still reachable on demand
    /// by name (the Reader handoff) or by an explicit, future browse.
    static let externalSubfolderName = "PDF"

    /// Whether the enumerator should skip descending into this directory,
    /// matched by folder name, case-insensitively.
    static func isExcludedScanDirectory(_ url: URL) -> Bool {
        url.lastPathComponent.caseInsensitiveCompare(externalSubfolderName) == .orderedSame
    }
}

nonisolated enum LibraryScanner {
    /// Phase one's yield: everything the lists and reader need, without
    /// the person-mention scan — which the index computes in a second
    /// pass so it never holds up the library appearing.
    struct CoreResult: Sendable {
        var byID: [String: IndexEntry] = [:]
        var backlinks: [String: [BacklinkRef]] = [:]
        var revisionOf: [String: String] = [:]
        var retractedIDs: Set<String> = []
        var timeline: [IndexEntry] = []
        var unreadable: [UnreadableFile] = []
    }

    /// One file's read: either a decoded document with the modification
    /// date used to settle id collisions, or the reason it wouldn't read.
    private enum FileOutcome: Sendable {
        case decoded(doc: LiquidDoc, modDate: Date)
        case unreadable(UnreadableFile)
    }

    /// The folder often lives in iCloud Drive: a file another device
    /// wrote may exist here only as a hidden ".<name>.icloud"
    /// placeholder, which the content scan (skipping hidden files)
    /// never sees — and asking iCloud for the folder alone does not
    /// reliably fetch its contents. So ask for every placeholder by
    /// its real name; as files land, the folder watcher fires and the
    /// next rescan reads them.
    static func requestICloudDownloads(in folder: URL) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: folder)
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: nil,
            options: [.skipsPackageDescendants]) else { return }
        for case let url as URL in enumerator {
            if KnowledgeSpaceFolders.isExcludedScanDirectory(url) {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == "icloud" else { continue }
            // ".<name>.icloud" → "<name>", the item's logical URL.
            var name = url.lastPathComponent
            if name.hasPrefix(".") { name.removeFirst() }
            name = String(name.dropLast(".icloud".count))
            guard !name.isEmpty else { continue }
            let real = url.deletingLastPathComponent().appendingPathComponent(name)
            try? FileManager.default.startDownloadingUbiquitousItem(at: real)
        }
    }

    /// How many documents exist here only as ".<name>.icloud"
    /// placeholders — files another device wrote that iCloud has not
    /// delivered yet. The content scan cannot see them (they are
    /// hidden), so a caller that finds no documents can still tell
    /// "empty folder" from "folder still downloading".
    static func pendingDocumentDownloads(in folder: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: nil,
            options: [.skipsPackageDescendants]) else { return 0 }
        var count = 0
        for case let url as URL in enumerator {
            if KnowledgeSpaceFolders.isExcludedScanDirectory(url) {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == "icloud" else { continue }
            var name = url.lastPathComponent
            if name.hasPrefix(".") { name.removeFirst() }
            name = String(name.dropLast(".icloud".count))
            if name.lowercased().hasSuffix("." + LiquidDoc.fileExtension) {
                count += 1
            }
        }
        return count
    }

    /// Reads and decodes the whole folder, in parallel across cores — a
    /// large community folder is thousands of independent files, and
    /// decoding them one at a time on a single thread was the bulk of the
    /// launch wait — then builds the id map, backlinks, and timeline.
    static func scanCore(folder: URL) async -> CoreResult {
        var result = CoreResult()
        requestICloudDownloads(in: folder)
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return result }

        // A cheap directory walk to gather the document URLs; the costly
        // read-and-decode of each then runs concurrently below.
        var urls: [URL] = []
        for case let url as URL in enumerator {
            if KnowledgeSpaceFolders.isExcludedScanDirectory(url) {
                enumerator.skipDescendants()
                continue
            }
            guard LiquidDoc.isDocumentFile(url) else { continue }
            urls.append(url)
        }

        let outcomes: [FileOutcome] = await withTaskGroup(of: FileOutcome.self) { group in
            for url in urls {
                group.addTask { decode(url) }
            }
            var collected: [FileOutcome] = []
            collected.reserveCapacity(urls.count)
            for await outcome in group { collected.append(outcome) }
            return collected
        }

        var docs: [LiquidDoc] = []
        var modificationDates: [String: Date] = [:]
        var duplicateIDs: Set<String> = []

        for outcome in outcomes {
            switch outcome {
            case .unreadable(let file):
                result.unreadable.append(file)
            case .decoded(let doc, let modDate):
                if let existingDate = modificationDates[doc.id] {
                    // Two files claim the same id: keep the newer one, flag both.
                    duplicateIDs.insert(doc.id)
                    if modDate > existingDate {
                        modificationDates[doc.id] = modDate
                        docs.removeAll { $0.id == doc.id }
                        docs.append(doc)
                    }
                } else {
                    modificationDates[doc.id] = modDate
                    docs.append(doc)
                }
            }
        }

        for doc in docs {
            result.byID[doc.id] = IndexEntry(doc: doc, hasDuplicate: duplicateIDs.contains(doc.id))
            for link in doc.links {
                result.backlinks[link.to, default: []]
                    .append(BacklinkRef(fromID: doc.id, rel: link.rel, fragment: link.fragment))
                if link.rel == "revises" {
                    result.revisionOf[link.to] = doc.id
                }
                if link.rel == "retracts" {
                    result.retractedIDs.insert(link.to)
                }
            }
        }

        result.timeline = result.byID.values.sorted { $0.doc.listedDate < $1.doc.listedDate }
        return result
    }

    /// Reads one file off the shared pool: its decoded document and
    /// modification date, or why it could not be read.
    private static func decode(_ url: URL) -> FileOutcome {
        do {
            let data = try Data(contentsOf: url)
            let doc = try LiquidDoc.decode(data: data, fileURL: url)
            let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            return .decoded(doc: doc, modDate: modDate)
        } catch {
            return .unreadable(UnreadableFile(fileURL: url, reason: error.localizedDescription))
        }
    }

    /// Every person, found by name in the documents' words — contact
    /// records from the folder's People.json (Digital Letters' directory)
    /// keyed by record id, and identity cards keyed by their document id.
    /// Each matches on the display name, credited author or credit name,
    /// other names, and aliases, whole words only — "Ted" never matches
    /// "quoted".
    static func mentions(in timeline: [IndexEntry],
                         folder: URL) -> [String: [String]] {
        var nameSets: [(cardID: String, names: [String])] = []
        func nameSet(id: String, names: [String]) {
            var kept: [String] = []
            for name in names {
                let trimmed = name.trimmingCharacters(in: .whitespaces).lowercased()
                if trimmed.count >= 2, !kept.contains(trimmed) {
                    kept.append(trimmed)
                }
            }
            if !kept.isEmpty { nameSets.append((id, kept)) }
        }
        if let data = try? Data(contentsOf: folder
                .appendingPathComponent(PersonDirectory.communityFileName)),
           let people = try? JSONDecoder().decode([Person].self, from: data) {
            for person in people {
                nameSet(id: person.id,
                        names: [person.displayName, person.creditName]
                            + person.otherNames + (person.aliases ?? []))
            }
        }
        for entry in timeline where entry.doc.documentType == IdentityCard.documentType {
            let card = IdentityCard(doc: entry.doc)
            nameSet(id: entry.id,
                    names: [card.displayName, entry.doc.author] + card.aliases)
        }
        guard !nameSets.isEmpty else { return [:] }

        var mentions: [String: [String]] = [:]
        for entry in timeline.reversed()
        where entry.doc.documentType != IdentityCard.documentType {
            // Content only: the Visual-Meta appendix is metadata, and its
            // self-citation names the author — not a mention in the words.
            let appendixIDs = entry.doc.visualMetaParagraphIDs
            let text = (entry.doc.body ?? [])
                .filter { !appendixIDs.contains($0.id) }
                .map(\.text)
                .joined(separator: "\n")
                .lowercased()
            guard !text.isEmpty else { continue }
            for set in nameSets
            where set.names.contains(where: { containsWholeName($0, in: text) }) {
                mentions[set.cardID, default: []].append(entry.id)
            }
        }
        return mentions
    }

    /// True when the lowercased name appears in the lowercased text as
    /// whole words — no letter running into it on either side.
    private static func containsWholeName(_ name: String, in text: String) -> Bool {
        var search = text.startIndex..<text.endIndex
        while let range = text.range(of: name, range: search) {
            let clearBefore = range.lowerBound == text.startIndex
                || !text[text.index(before: range.lowerBound)].isLetter
            let clearAfter = range.upperBound == text.endIndex
                || !text[range.upperBound].isLetter
            if clearBefore && clearAfter { return true }
            search = range.upperBound..<text.endIndex
        }
        return false
    }
}
