//
//  FlexibleRoomSpaceView.swift
//  Knowledge Space
//
//  Room-scale flexible space: every .liquid.json document in the community
//  folder floats as a freely moveable card anywhere in the room. Tap a card
//  to reveal the body; drag it to place it exactly where it belongs.
//  Positions persist across sessions in UserDefaults, keyed to the folder.
//
//  All document types the macOS app knows — note, journal, thought, letter,
//  book, source, quote, annotation, transcript, extract, article, and more —
//  appear here with their own colour and icon so the space reads at a glance.
//
//  Compositor note: SwiftUI attachments carry a memory cost in backboardd.
//  The cap (flexSpaceCap) keeps the total below the level that triggers
//  system UI kills; see SphereWeaveVolume.swift for context.
//

#if os(visionOS)
import SwiftUI
import RealityKit

// MARK: - Space

/// The room-scale flexible space. All folder documents float free — no fixed
/// plane, no concept-map engine. The root entity sits at the world origin;
/// card positions are in room meters relative to it.
struct FlexibleRoomSpaceView: View {
    @Environment(AuthorMapState.self) private var state

    /// Card positions in room-space meters (world origin, z negative = forward).
    @State private var positions: [String: SIMD3<Float>] = [:]

    /// Start position when a drag begins, so the whole delta can be replayed.
    @State private var dragStarts: [String: SIMD3<Float>] = [:]

    /// Bumped on every drag frame to trigger a RealityView update closure.
    @State private var revision = 0

    /// Cards always face the viewer by default; can be switched off.
    @AppStorage("flexSpaceBillboard") private var billboard = true

    /// 1 meter expressed in SwiftUI points, from the physical environment.
    @PhysicalMetric(from: .meters) private var meterInPoints = 1.0

    private static let rootName = "FlexRoot"
    private static let cardPrefix = "flexcard:"
    static let cap = 100
    private static let posKeyPrefix = "flexRoomPositions:"

    var body: some View {
        RealityView { content, attachments in
            let root = Entity()
            root.name = Self.rootName
            content.add(root)
            placeCards(root: root, attachments: attachments)
        } update: { content, attachments in
            _ = revision
            guard let root = content.entities.first(where: { $0.name == Self.rootName })
            else { return }
            placeCards(root: root, attachments: attachments)
        } attachments: {
            ForEach(displayDocs, id: \.id) { doc in
                Attachment(id: doc.id) {
                    FlexRoomCard(doc: doc)
                        .hoverEffect()
                        .gesture(dragGesture(for: doc.id))
                }
            }
        }
        .onAppear {
            state.isFlexSpaceOpen = true
            loadPositions()
        }
        .onDisappear {
            state.isFlexSpaceOpen = false
            savePositions()
        }
        .onChange(of: state.weaveDocuments.count) {
            // Newly arrived documents get a seed position.
            for (index, doc) in displayDocs.enumerated() where positions[doc.id] == nil {
                positions[doc.id] = seedPosition(index: index, total: displayDocs.count)
            }
            revision += 1
        }
    }

    // MARK: - Documents

    var displayDocs: [LiquidDoc] {
        Array(state.weaveDocuments
            .filter { !$0.draft }
            .sorted { $0.listedDate > $1.listedDate }
            .prefix(Self.cap))
    }

    // MARK: - Layout

    /// Places or updates every card under the root. Existing entities are
    /// reused (attachment identity is stable per id); new ones are adopted;
    /// entities whose document left the display set are removed.
    private func placeCards(root: Entity, attachments: RealityViewAttachments) {
        var kept = Set<ObjectIdentifier>()

        for doc in displayDocs {
            let name = Self.cardPrefix + doc.id
            let card: Entity
            if let existing = root.findEntity(named: name) {
                card = existing
            } else if let attachment = attachments.entity(for: doc.id) {
                attachment.name = name
                if billboard { attachment.components.set(BillboardComponent()) }
                root.addChild(attachment)
                card = attachment
            } else {
                continue
            }
            card.position = positions[doc.id] ?? SIMD3(0, 1.4, -1.5)
            kept.insert(ObjectIdentifier(card))
        }

        for child in Array(root.children) where !kept.contains(ObjectIdentifier(child)) {
            child.removeFromParent()
        }
    }

    // MARK: - Positions

    private var positionsKey: String? {
        guard let folder = state.folderURL else { return nil }
        return Self.posKeyPrefix + folder.path
    }

    private func loadPositions() {
        let docs = displayDocs
        if let key = positionsKey,
           let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: [Float]] {
            for (id, xyz) in stored where xyz.count == 3 {
                positions[id] = SIMD3(xyz[0], xyz[1], xyz[2])
            }
        }
        // Seed positions for documents not yet placed.
        for (index, doc) in docs.enumerated() where positions[doc.id] == nil {
            positions[doc.id] = seedPosition(index: index, total: docs.count)
        }
    }

    private func savePositions() {
        guard let key = positionsKey else { return }
        var out: [String: [Float]] = [:]
        for (id, p) in positions { out[id] = [p.x, p.y, p.z] }
        UserDefaults.standard.set(out, forKey: key)
    }

    /// Fibonacci-sphere distribution around the viewer, biased toward the
    /// forward hemisphere. Cards range from 1.0 m to 1.9 m out, from
    /// 0.9 m to 2.1 m high — filling the room without ending up behind
    /// the viewer on first open.
    private func seedPosition(index: Int, total: Int) -> SIMD3<Float> {
        let goldenAngle = Float.pi * (3.0 - sqrt(5.0))
        let theta = goldenAngle * Float(index)
        let t = total > 1 ? Float(index) / Float(total - 1) : 0.5
        let y = 0.9 + t * 1.2                       // 0.9 m … 2.1 m
        let r = 1.0 + Float(index % 4) * 0.3        // 1.0 m … 1.9 m
        // z is always negative (forward) by reflecting the absolute value.
        return SIMD3(r * cos(theta), y, -abs(r * sin(theta)) - 0.5)
    }

    // MARK: - Drag

    private func dragGesture(for id: String) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragStarts[id] == nil {
                    dragStarts[id] = positions[id] ?? SIMD3(0, 1.4, -1.5)
                }
                guard let start = dragStarts[id] else { return }
                let m = Float(max(meterInPoints, 1))
                let delta = SIMD3<Float>(
                    Float(value.translation3D.x) / m,
                    Float(value.translation3D.y) / m,
                    Float(value.translation3D.z) / m
                )
                positions[id] = start + delta
                revision += 1
            }
            .onEnded { _ in
                dragStarts[id] = nil
                savePositions()
            }
    }
}

// MARK: - Card

/// A single document card for the flexible room space. Tap to reveal the
/// body; the type badge and its colour identify the document at arm's length.
struct FlexRoomCard: View {
    let doc: LiquidDoc
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {

            // Type badge
            Label(displayType, systemImage: typeIcon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(typeColor)
                .textCase(.uppercase)

            // Title
            Text(doc.title)
                .font(.system(size: 14, weight: .semibold, design: .serif))
                .foregroundStyle(.primary)
                .lineLimit(expanded ? 4 : 2)

            // Body excerpt — visible only when expanded
            if expanded, let excerpt = bodyExcerpt {
                Text(excerpt)
                    .font(.system(size: 11, design: .serif))
                    .foregroundStyle(.secondary)
                    .lineLimit(10)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 2)
            }

            // Footer: date left, author right
            HStack {
                Text(doc.listedDateText)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Spacer()
                if !doc.author.isEmpty {
                    Text(doc.author)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
        .frame(minWidth: 150, maxWidth: expanded ? 300 : 210)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(expanded
                      ? AnyShapeStyle(Color(white: 0.14))
                      : AnyShapeStyle(.regularMaterial))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(typeColor.opacity(expanded ? 0.55 : 0.3), lineWidth: 1)
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            withAnimation(.spring(duration: 0.22)) { expanded.toggle() }
        }
    }

    private var bodyExcerpt: String? {
        guard let body = doc.body else { return nil }
        let text = body.prefix(4)
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    private var displayType: String {
        if let t = doc.documentType, !t.isEmpty { return t }
        return doc.wraps != nil ? "article" : "note"
    }

    private var typeIcon: String {
        switch doc.documentType {
        case "note":                return "note.text"
        case "thought":             return "lightbulb"
        case "journal":             return "book.closed"
        case "letter":              return "envelope"
        case "book":                return "books.vertical"
        case "transcript":          return "quote.bubble"
        case "extract":             return "text.badge.checkmark"
        case "source":              return "doc.richtext"
        case "quote":               return "text.quote"
        case "annotation":          return "highlighter"
        case "article", "external": return "newspaper"
        case "inspiration":         return "sparkles"
        case "digest":              return "square.stack"
        case "meeting":             return "person.3"
        case "project":             return "folder"
        case "personal":            return "person"
        case "rfc":                 return "list.bullet"
        default:
            return doc.wraps != nil ? "newspaper" : "doc"
        }
    }

    private var typeColor: Color {
        switch doc.documentType {
        case "note":                return .yellow
        case "thought":             return .orange
        case "journal":             return .green
        case "letter":              return .blue
        case "book":                return .purple
        case "transcript":          return .teal
        case "extract":             return .mint
        case "source":              return .indigo
        case "quote":               return .cyan
        case "annotation":          return .pink
        case "article", "external": return Color(white: 0.7)
        case "inspiration":         return .red
        case "digest":              return .brown
        case "meeting":             return .teal
        case "project":             return .blue
        case "personal":            return .orange
        default:
            return doc.wraps != nil ? Color(white: 0.7) : .white
        }
    }
}

// MARK: - Controls window

/// Minimal control bar for the flexible room space: return to the library,
/// write a new note, close the space.
struct FlexSpaceControlsView: View {
    @Environment(AuthorMapState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        HStack(spacing: 16) {
            Button {
                openWindow(id: "Library")
            } label: {
                Label("Library", systemImage: "books.vertical")
            }

            if state.folderURL != nil {
                Button {
                    state.prepareNewNote()
                    openWindow(id: "MapNoteEditor")
                } label: {
                    Label("New Note", systemImage: "square.and.pencil")
                }
            }

            Text("Room Space")
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                Task { @MainActor in
                    await dismissImmersiveSpace()
                    dismissWindow(id: "FlexSpaceControls")
                    openWindow(id: "Library")
                }
            } label: {
                Label("Close", systemImage: "xmark.circle")
            }
            .labelStyle(.iconOnly)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(minWidth: 400)
        .onAppear { state.isFlexSpaceOpen = true }
    }
}

#endif
