import Foundation

// The receiving end of the Safari extension's one-click capture. The
// extension's native handler writes each captured conversation, whole,
// into a shared App Group container; the app watches that container and
// files what appears, landing it in the Inbox as a draft the reader can
// look at in their own time. The app owns the user's name — the handler
// stamps a placeholder, and the name is set here from the app's own user
// record, so there is nothing to configure in the extension and no place
// for the name to go stale.

#if os(macOS)
extension AppState {

    /// The App Group both the app target and the extension handler must
    /// carry as an entitlement. Change here and in both targets' entitlements
    /// together, or the handoff has no shared floor to meet on.
    static let aiInboxAppGroupID = "group.info.augmentedtext.knowledgespace"

    /// The directory the extension drops completed captures into. Nil when
    /// the App Group entitlement is absent — the feature then does nothing
    /// rather than crashing, so a build without the extension still runs.
    static var aiInboxIncomingURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: aiInboxAppGroupID)?
            .appendingPathComponent("Inbox/incoming", isDirectory: true)
    }

    /// Begins watching the inbox and files whatever is already waiting.
    /// Safe to call more than once — the watch is installed only once.
    func startWatchingAIInbox() {
        guard let incoming = Self.aiInboxIncomingURL else { return }
        try? FileManager.default.createDirectory(
            at: incoming, withIntermediateDirectories: true)
        drainAIInbox()
        guard aiInboxWatcher == nil else { return }
        aiInboxWatcher = FolderWatcher(url: incoming) { [weak self] in
            Task { @MainActor in self?.drainAIInbox() }
        }
    }

    /// Reads every completed capture, files it, and clears it. A capture
    /// that will not parse is moved aside so it is not retried forever, and
    /// the failure is shown — a silent partial capture is worse than none.
    /// Files are matched by the `.aiconv.json` suffix, so the handler's
    /// temp-then-rename write is never read half-formed.
    func drainAIInbox() {
        guard let incoming = Self.aiInboxIncomingURL, index.folderURL != nil,
              let files = try? FileManager.default.contentsOfDirectory(
                at: incoming, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]) else { return }
        for url in files
        where url.lastPathComponent.lowercased().hasSuffix(".aiconv.json") {
            guard let data = try? Data(contentsOf: url) else { continue }
            if let doc = ingestAICapture(data: data) {
                try? FileManager.default.removeItem(at: url)
                selectedDocID = doc.id
            } else {
                moveAsideFailedCapture(url)
            }
        }
    }

    private func moveAsideFailedCapture(_ url: URL) {
        let failed = url.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("failed", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: failed, withIntermediateDirectories: true)
        try? FileManager.default.moveItem(
            at: url, to: failed.appendingPathComponent(url.lastPathComponent))
        showNote("Could not read a captured conversation — moved it aside. Nothing was imported.")
    }

    /// Files one capture into the library as a draft: a minted id, the
    /// user's own name stamped over the extension's placeholder, its human
    /// speakers made known to People (models never are), and its provenance
    /// and source kept. A re-import of the same conversation — matched by
    /// the vendor's own conversation id — updates in place and preserves any
    /// verification the reader has already set.
    @discardableResult
    func ingestAICapture(data: Data) -> LiquidDoc? {
        guard let folderURL = index.folderURL,
              let parsed = AIConversationImporter.importJSON(data, userName: authorName)
        else { return nil }

        let existing = parsed.conversationID.flatMap { convID in
            index.allByID.values.first { $0.doc.aiSource?.conversationID == convID }?.doc
        }
        let created = existing?.created ?? Date.now
        let id = existing?.id ?? LiquidAddress.makeID(author: authorName, created: created) {
            self.index.isIDTaken($0)
        }

        // Carry forward verification the reader set on the earlier capture,
        // matched by paragraph id, so a re-import does not erase judgement.
        var body = parsed.body
        if let priorBody = existing?.body {
            var priorVerification: [String: String] = [:]
            for paragraph in priorBody {
                if let verification = paragraph.verification {
                    priorVerification[paragraph.id] = verification
                }
            }
            if !priorVerification.isEmpty {
                body = body.map { paragraph in
                    var paragraph = paragraph
                    if let kept = priorVerification[paragraph.id] {
                        paragraph.verification = kept
                    }
                    return paragraph
                }
            }
        }

        let fileURL = existing?.fileURL
            ?? folderURL.appendingPathComponent(id)
                .appendingPathExtension(LiquidDoc.fileExtension)
        let doc = LiquidDoc(format: LiquidDoc.knownFormat,
                            id: id,
                            title: parsed.title,
                            author: authorName,
                            created: created,
                            body: body,
                            links: [],
                            wraps: nil,
                            date: parsed.date,
                            draft: true,
                            documentType: LiquidDoc.DocumentType.aiConversation.rawValue,
                            aiSource: parsed.aiSource,
                            agents: parsed.agents,
                            fileURL: fileURL)
        guard (try? doc.jsonData().write(to: fileURL, options: .atomic)) != nil else {
            showNote("Could not write the captured conversation.")
            return nil
        }
        ensureSpeakersKnown(parsed.personSpeakers)
        index.rescan()
        showNote(existing == nil
            ? "Captured “\(parsed.title)” into the Inbox as a draft."
            : "Updated “\(parsed.title)” from a fresh capture.")
        return doc
    }
}
#endif
