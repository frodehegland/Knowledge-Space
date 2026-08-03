import Foundation

/// The bridge between the Knowledge Space app and its visionOS widgets.
///
/// Widgets run in their own process and cannot reach the community folder
/// through the app's security-scoped bookmark. So the app writes a small
/// snapshot of the To Do and Journal lists into a shared App Group
/// container after each folder scan, and the widget reads it.
///
/// This file must belong to **both** targets: the "Knowledge Space" app
/// and the widget extension. It is pure Foundation, so it compiles on
/// every platform the app targets.
///
/// Setup (one time, in Xcode's Signing & Capabilities for both targets):
///  1. Add the App Group capability.
///  2. Add the group id below to each target.
enum KSWidget {

    /// The App Group both the app and the widget read and write through.
    /// Derived from the app's bundle id; change here if the group id you
    /// create differs.
    static let appGroupID = "group.info.futuretextlab.knowledgespace"

    /// The two lists a widget can show. Each maps to a snapshot file in
    /// the container and to the deep link a tap on the widget opens.
    enum ListKind: String, Codable, CaseIterable, Sendable {
        case toDo
        case journal

        var fileName: String { "widget-\(rawValue).json" }

        var title: String {
            switch self {
            case .toDo: "To Do"
            case .journal: "Journal"
            }
        }

        var systemImage: String {
            switch self {
            case .toDo: "checklist"
            case .journal: "book.closed"
            }
        }

        /// The deep link a tap/pinch on the widget opens — routed by the
        /// app to its listing window. e.g. `knowledgespace://list/toDo`.
        var url: URL { URL(string: "knowledgespace://list/\(rawValue)")! }

        /// Reads a list kind back from an opened deep-link URL.
        static func from(url: URL) -> ListKind? {
            guard url.scheme == "knowledgespace", url.host == "list",
                  let raw = url.pathComponents.last else { return nil }
            return ListKind(rawValue: raw)
        }
    }

    /// One row in a widget list — the least a glanceable list needs.
    struct Item: Codable, Identifiable, Hashable, Sendable {
        var id: String
        var title: String
        /// The place the note carries, or empty.
        var subtitle: String
        /// The note's own listed date, already formatted.
        var dateText: String
    }

    /// A list's snapshot: its rows and when the app wrote them.
    struct Snapshot: Codable, Sendable {
        var items: [Item]
        var generatedAt: Date

        static let empty = Snapshot(items: [], generatedAt: .distantPast)
    }

    /// The shared container, or nil until the App Group is granted to the
    /// running target — every read and write no-ops gracefully until then.
    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// The app calls this after a scan to hand the widget a fresh list.
    static func write(_ items: [Item], for kind: ListKind) {
        guard let dir = containerURL else { return }
        let snapshot = Snapshot(items: items, generatedAt: .now)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: dir.appendingPathComponent(kind.fileName), options: .atomic)
    }

    /// The widget reads its list from here; an empty snapshot when the app
    /// has not published one yet.
    static func read(_ kind: ListKind) -> Snapshot {
        guard let dir = containerURL,
              let data = try? Data(contentsOf: dir.appendingPathComponent(kind.fileName)),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return .empty }
        return snapshot
    }
}
