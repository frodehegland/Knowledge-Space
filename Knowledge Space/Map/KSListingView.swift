#if os(visionOS)
import SwiftUI

/// A tall framed list of one library category — To Do or Journal — the
/// window a widget opens into, and the first seed of an Augmented
/// Library-style browser. It reads the live folder scan when the app has
/// a community folder open, and falls back to the widget's own snapshot
/// when it does not yet (a cold launch from a widget tap).
struct KSListingView: View {
    @Environment(AuthorMapState.self) private var mapState
    let kind: KSWidget.ListKind

    private var liveDocuments: [LiquidDoc] {
        switch kind {
        case .toDo: mapState.toDoDocuments
        case .journal: mapState.journalDocuments
        }
    }

    /// The snapshot the widget itself shows — stood in for the live list
    /// until the folder is (re)opened.
    private var snapshotItems: [KSWidget.Item] { KSWidget.read(kind).items }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: kind.systemImage)
                    .font(.title2)
                Text(kind.title)
                    .font(.largeTitle.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 18)
            Divider()

            if !liveDocuments.isEmpty {
                List(liveDocuments) { doc in
                    Button {
                        mapState.openDocument(url: doc.fileURL)
                    } label: {
                        row(title: doc.title,
                            subtitle: doc.location ?? "",
                            dateText: doc.listedDateText)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            } else if !snapshotItems.isEmpty {
                List(snapshotItems) { item in
                    row(title: item.title, subtitle: item.subtitle, dateText: item.dateText)
                }
                .listStyle(.plain)
                .safeAreaInset(edge: .bottom) {
                    Text("Open the community folder to browse and edit these.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding()
                }
            } else {
                ContentUnavailableView(
                    "Nothing in \(kind.title)",
                    systemImage: kind.systemImage,
                    description: Text("Notes marked \(kind.title) appear here as the folder syncs."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 380, minHeight: 560)
        // A widget tap can be the app's first act — bring the last
        // folder back so the list is live, not just the snapshot.
        .onAppear { mapState.reopenLastDocument() }
    }

    private func row(title: String, subtitle: String, dateText: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.title3)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(dateText)
                if !subtitle.isEmpty { Text(subtitle).lineLimit(1) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
#endif
