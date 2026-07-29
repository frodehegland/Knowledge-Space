import Foundation
import SafariServices
import os.log

// The native end of the one-click capture. Safari delivers the background
// worker's messages here, one per chunk; this handler reassembles them and
// writes the finished capture — whole — into the shared App Group container,
// where the Knowledge Space app watches and files it.
//
// Reassembly must survive across separate `beginRequest` invocations (each
// chunk is its own call, and the handler process may not persist between
// them), so partial chunks are staged on disk in the container and joined
// only when the last one arrives. The final file lands with an atomic move,
// so the app never reads a half-written capture.
//
// This handler does not know or stamp the user's name: the app owns that
// and stamps its own user record when it files the capture, so there is
// nothing to configure here and no place for the name to go stale.

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    /// Must match the App Group entitlement on both this extension target
    /// and the Knowledge Space app target, and `AppState.aiInboxAppGroupID`.
    static let appGroupID = "group.info.augmentedtext.knowledgespace"

    private let log = Logger(subsystem: "info.augmentedtext.knowledgespace.capture",
                             category: "handler")

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]

        guard let message,
              let id = message["id"] as? String,
              let seq = message["seq"] as? Int,
              let total = message["total"] as? Int,
              let chunk = message["chunk"] as? String else {
            complete(context, ["error": "Malformed capture message."])
            return
        }

        do {
            let final = try store(chunk: chunk, id: id, seq: seq, total: total)
            if let final {
                complete(context, ["ok": true, "id": final])
            } else {
                // Acknowledge an intermediate chunk without a verdict.
                complete(context, ["received": seq])
            }
        } catch {
            log.error("Capture write failed: \(error.localizedDescription)")
            complete(context, ["ok": false, "error": "Could not stage the capture: \(error.localizedDescription)"])
        }
    }

    // MARK: - Staging and assembly

    /// Writes one chunk to the container's partials area and, when the last
    /// chunk has arrived and every part is present, joins them and moves the
    /// finished capture atomically into the inbox. Returns the final file
    /// name when it wrote one, else nil.
    private func store(chunk: String, id: String, seq: Int, total: Int) throws -> String? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID) else {
            throw HandlerError.noContainer
        }
        let fm = FileManager.default
        let inbox = container.appendingPathComponent("Inbox", isDirectory: true)
        let incoming = inbox.appendingPathComponent("incoming", isDirectory: true)
        let partials = inbox.appendingPathComponent("partials", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: incoming, withIntermediateDirectories: true)
        try fm.createDirectory(at: partials, withIntermediateDirectories: true)

        let partURL = partials.appendingPathComponent("\(seq).part")
        try Data(chunk.utf8).write(to: partURL, options: .atomic)

        // Not the last chunk, or parts still missing: wait for the rest.
        guard seq == total - 1 else { return nil }
        for i in 0..<total {
            let expected = partials.appendingPathComponent("\(i).part")
            guard fm.fileExists(atPath: expected.path) else { return nil }
        }

        var joined = Data()
        for i in 0..<total {
            joined.append(try Data(contentsOf: partials.appendingPathComponent("\(i).part")))
        }

        // Atomic landing: a temp name the app's suffix match ignores, then
        // a rename to the real name, which the folder watcher sees whole.
        let finalName = "\(id).aiconv.json"
        let staged = incoming.appendingPathComponent("\(id).staging")
        let destination = incoming.appendingPathComponent(finalName)
        try joined.write(to: staged, options: .atomic)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: staged, to: destination)
        try? fm.removeItem(at: partials)
        return finalName
    }

    private func complete(_ context: NSExtensionContext, _ payload: [String: Any]) {
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: payload]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    private enum HandlerError: LocalizedError {
        case noContainer
        var errorDescription: String? {
            switch self {
            case .noContainer:
                "The App Group container is unavailable — check the App Group entitlement."
            }
        }
    }
}
