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
            let result = LibraryScanner.scan(folder: folderURL)
            await MainActor.run {
                guard generation == self.scanGeneration else { return }
                self.allByID = result.byID
                self.fullBacklinks = result.backlinks
                self.fullTimeline = result.timeline
                self.fullMentions = result.mentions
                self.revisionOf = result.revisionOf
                self.unreadableFiles = result.unreadable
                self.supersededIDs = Set(result.revisionOf.keys)
                self.retractedIDs = result.retractedIDs
                self.applyArchiveFilter()
                self.isScanning = false
            }
        }
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

nonisolated enum LibraryScanner {
    struct Result: Sendable {
        var byID: [String: IndexEntry] = [:]
        var backlinks: [String: [BacklinkRef]] = [:]
        var revisionOf: [String: String] = [:]
        var retractedIDs: Set<String> = []
        var timeline: [IndexEntry] = []
        var unreadable: [UnreadableFile] = []
        /// Card id → the documents whose words name that card's person,
        /// newest first. Matched against the card's display name, its
        /// credited author, and every alias it carries.
        var mentions: [String: [String]] = [:]
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
        for case let url as URL in enumerator
        where url.pathExtension.lowercased() == "icloud" {
            // ".<name>.icloud" → "<name>", the item's logical URL.
            var name = url.lastPathComponent
            if name.hasPrefix(".") { name.removeFirst() }
            name = String(name.dropLast(".icloud".count))
            guard !name.isEmpty else { continue }
            let real = url.deletingLastPathComponent().appendingPathComponent(name)
            try? FileManager.default.startDownloadingUbiquitousItem(at: real)
        }
    }

    static func scan(folder: URL) -> Result {
        var result = Result()
        requestICloudDownloads(in: folder)
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return result }

        var docs: [LiquidDoc] = []
        var modificationDates: [String: Date] = [:]
        var duplicateIDs: Set<String> = []

        for case let url as URL in enumerator {
            guard LiquidDoc.isDocumentFile(url) else { continue }
            do {
                let data = try Data(contentsOf: url)
                let doc = try LiquidDoc.decode(data: data, fileURL: url)
                let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
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
            } catch {
                result.unreadable.append(UnreadableFile(fileURL: url, reason: error.localizedDescription))
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
        result.mentions = mentions(in: result.timeline, folder: folder)
        return result
    }

    /// Every person, found by name in the documents' words — contact
    /// records from the folder's People.json (Digital Letters' directory)
    /// keyed by record id, and identity cards keyed by their document id.
    /// Each matches on the display name, credited author or credit name,
    /// other names, and aliases, whole words only — "Ted" never matches
    /// "quoted".
    private static func mentions(in timeline: [IndexEntry],
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
            let text = entry.doc.bodyEditingText.lowercased()
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
