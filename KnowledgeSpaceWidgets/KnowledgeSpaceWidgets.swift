// KnowledgeSpaceWidgets.swift
//
// The visionOS widget bundle for Knowledge Space: two tall, framed lists
// — To Do and Journal — that a person pins to a wall or desk. Tapping one
// opens the app to the matching listing window.
//
// This file belongs to the **widget extension target only** — never the
// app. Add `WidgetShared.swift` (from the app) to the widget target too,
// so `KSWidget` is shared, and give both targets the same App Group.
//
// The list data comes from the snapshot the app writes after each folder
// scan (see AuthorMapState.publishWidgetSnapshots); the widget only reads.

import WidgetKit
import SwiftUI

// MARK: - Timeline

struct KSListEntry: TimelineEntry {
    let date: Date
    let kind: KSWidget.ListKind
    let items: [KSWidget.Item]
}

/// One provider, parameterised by which list it shows. It reads the
/// app's snapshot; the app reloads timelines on every scan, and this
/// refreshes hourly as a floor.
struct KSListProvider: TimelineProvider {
    let kind: KSWidget.ListKind

    func placeholder(in context: Context) -> KSListEntry {
        KSListEntry(date: .now, kind: kind, items: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (KSListEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<KSListEntry>) -> Void) {
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: .now)
            ?? Date.now.addingTimeInterval(3600)
        completion(Timeline(entries: [entry()], policy: .after(next)))
    }

    private func entry() -> KSListEntry {
        KSListEntry(date: .now, kind: kind, items: KSWidget.read(kind).items)
    }
}

// MARK: - View

struct KSListWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: KSListEntry

    /// The tall portrait frame holds many rows; the large frame fewer.
    private var rowCount: Int { family == .systemLarge ? 6 : 14 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: entry.kind.systemImage)
                Text(entry.kind.title)
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(.bottom, 8)
            Divider()

            if entry.items.isEmpty {
                Spacer()
                Text("Nothing yet")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(entry.items.prefix(rowCount)) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.body)
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                Text(item.dateText)
                                if !item.subtitle.isEmpty {
                                    Text(item.subtitle).lineLimit(1)
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 8)
            }
        }
        // Tapping (or pinching) the whole widget opens the app to this list.
        .widgetURL(entry.kind.url)
    }
}

// MARK: - Widgets

struct ToDoListWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "KSToDoList", provider: KSListProvider(kind: .toDo)) { entry in
            KSListWidgetView(entry: entry)
                .padding()
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("To Do")
        .description("Your To Do notes, framed on a surface.")
        .supportedFamilies([.systemExtraLargePortrait, .systemLarge])
        .supportedMountingStyles([.elevated])
        .widgetTexture(.glass)
    }
}

struct JournalWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "KSJournal", provider: KSListProvider(kind: .journal)) { entry in
            KSListWidgetView(entry: entry)
                .padding()
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Journal")
        .description("Your Journal entries, framed on a surface.")
        .supportedFamilies([.systemExtraLargePortrait, .systemLarge])
        .supportedMountingStyles([.elevated])
        .widgetTexture(.glass)
    }
}

@main
struct KnowledgeSpaceWidgets: WidgetBundle {
    var body: some Widget {
        ToDoListWidget()
        JournalWidget()
    }
}
