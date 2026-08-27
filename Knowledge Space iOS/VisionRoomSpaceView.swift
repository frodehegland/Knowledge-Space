//
//  VisionRoomSpaceView.swift
//  Knowledge Space iOS  (visionOS build)
//
//  Native visionOS room-scale experience for the iOS target.
//
//  VisionLibraryView  — the way-in window (folder picker + Enter Room Space).
//  VisionRoomSpaceView — immersive space, all .liquid.json docs as floating
//                        cards, fully draggable in x/y/z.
//  VisionRoomModel    — lightweight observable that scans the folder for every
//                       document (no author filter) and holds the card positions.
//  VisionRoomCard     — SwiftUI card per document type, tap to expand.
//
//  The .liquid.json format is the same one the macOS app reads: every field is
//  decoded by LiquidDoc.decode, so what the Mac writes the headset shows.
//

#if os(visionOS)
import SwiftUI
import RealityKit
import UniformTypeIdentifiers

// MARK: - Library

/// Transitional launcher: immediately enters the room space once a folder is
/// available. On first launch (no folder saved) it presents the picker; after
/// that each launch goes straight into the immersive room. The folder can be
/// changed later from the right-wrist Settings button.
struct VisionLibraryView: View {
    @Environment(NotesModel.self) private var notes
    @Environment(VisionRoomModel.self) private var roomModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var choosingFolder = false
    @State private var didOpen = false

    var body: some View {
        Group {
            if notes.folderURL == nil {
                ContentUnavailableView {
                    Label("No Community Folder", systemImage: "folder")
                } description: {
                    Text("Choose the folder your community shares. Every document in it will float in the room.")
                } actions: {
                    Button("Choose Folder…") { choosingFolder = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Opening room…")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(40)
        .frame(minWidth: 360, minHeight: 220)
        .fileImporter(isPresented: $choosingFolder,
                      allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                notes.openFolder(url)
                scanAndOpen(folder: url)
            }
        }
        .onAppear {
            if let folder = notes.folderURL {
                scanAndOpen(folder: folder)
            } else {
                choosingFolder = true
            }
        }
    }

    private func scanAndOpen(folder: URL) {
        roomModel.scan(folder: folder)
        guard !didOpen else { return }
        didOpen = true
        Task { @MainActor in
            _ = await openImmersiveSpace(id: "VisionRoomSpace")
            dismissWindow(id: "VisionLibrary")
        }
    }
}

// MARK: - Room space

/// Immersive space — all documents float in world-space meters, billboarding
/// toward the viewer. Pinch-drag to reposition in full x/y/z; tap to expand.
/// Positions are saved to UserDefaults keyed by folder path.
///
/// Each card is a pair: a RealityKit ModelEntity host (with InputTargetComponent
/// + CollisionComponent so the drag gesture can hit it) and a SwiftUI attachment
/// child (the visible card). DragGesture().targetedToAnyEntity() on the
/// RealityView drives the 3D position; the card's onTapGesture handles expand.
/// translation3D in an ImmersiveSpace is already in scene metres — no
/// @PhysicalMetric conversion needed.
struct VisionRoomSpaceView: View {
    @Environment(VisionRoomModel.self) private var roomModel
    @Environment(NotesModel.self) private var notes
    @Environment(\.openWindow) private var openWindow

    /// Stored card positions in room metres (world origin, z-negative = forward).
    @State private var positions: [String: SIMD3<Float>] = [:]
    /// Per-entity grab offsets (entity centre − grab point in world metres).
    /// Keyed by ObjectIdentifier(entity). Cleared on drag end.
    @State private var dragOffsets: [ObjectIdentifier: SIMD3<Float>] = [:]
    /// Bumped when the doc list changes to trigger the RealityView update closure.
    @State private var revision = 0
    /// IDs of currently expanded cards. Lifted out of VisionRoomCard so that
    /// toggling causes VisionRoomSpaceView to re-render, which drives the
    /// RealityView update closure — ensuring the attachment entity is
    /// re-adopted if RealityKit replaced it when the card's SwiftUI view changed.
    @State private var expandedIDs: Set<String> = []
    /// Set of FilterSpec.ids whose document types are hidden in the room (left arm toggle).
    @State private var hiddenTypeGroups: Set<String> = []
    /// IDs of documents selected via the right arm torus; dragging any selected card
    /// moves all selected cards as a group.
    @State private var selectedIDs: Set<String> = []
    @State private var armMenuLeft  = VisionArmMenu(chirality: .left)
    @State private var armMenuRight = VisionArmMenu(chirality: .right)
    /// Mirrors isMenuExpanded for each arm so SwiftUI re-renders on pinch.
    @State private var menuLeftExpanded  = false
    @State private var menuRightExpanded = false
    /// Live entity references by doc id; populated in placeCards for group-drag.
    @State private var entityByID: [String: Entity] = [:]
    /// Starting positions of all selected cards at the moment a group drag begins.
    @State private var groupDragStartPositions: [String: SIMD3<Float>] = [:]
    /// World position of the dragged card at the start of the group drag.
    @State private var groupDragAnchorStart: SIMD3<Float>? = nil
    /// Retained for its lifetime — releasing it stops hand-joint tracking.
    @State private var trackingSession: SpatialTrackingSession?

    private static let rootName = "VRoomRoot"
    private static let hostPrefix = "vhost:"   // host entity — receives drag
    private static let attachPrefix = "vatn:"  // SwiftUI attachment child

    private var visibleDocs: [LiquidDoc] {
        guard !hiddenTypeGroups.isEmpty else { return roomModel.docs }
        return roomModel.docs.filter { doc in
            let typeKey = doc.documentType ?? (doc.wraps != nil ? "external" : "note")
            return !VisionArmMenu.filters.contains { spec in
                hiddenTypeGroups.contains(spec.id) && spec.types.contains(typeKey)
            }
        }
    }

    var body: some View {
        RealityView { content, attachments in
            let root = Entity()
            root.name = Self.rootName
            content.add(root)
            // Wrist + knuckle anchors must be top-level in content so RealityKit
            // delivers hand-tracking transforms to them every frame.
            for anchor in armMenuLeft.buildEager()  { content.add(anchor) }
            for anchor in armMenuRight.buildEager() { content.add(anchor) }
            armMenuLeft.updateSubscription = content.subscribe(to: SceneEvents.Update.self) { [armMenuLeft] _ in
                MainActor.assumeIsolated { armMenuLeft.layout() }
            }
            armMenuRight.updateSubscription = content.subscribe(to: SceneEvents.Update.self) { [armMenuRight] _ in
                MainActor.assumeIsolated { armMenuRight.layout() }
            }
            armMenuLeft.seatAttachments(attachments)
            armMenuRight.seatAttachments(attachments)
            placeCards(root: root, attachments: attachments)
        } update: { content, attachments in
            _ = revision
            _ = expandedIDs
            _ = hiddenTypeGroups
            _ = selectedIDs
            _ = menuLeftExpanded
            _ = menuRightExpanded
            armMenuLeft.seatAttachments(attachments)
            armMenuRight.seatAttachments(attachments)
            guard let root = content.entities.first(where: { $0.name == Self.rootName })
            else { return }
            placeCards(root: root, attachments: attachments)
        } attachments: {
            ForEach(visibleDocs, id: \.id) { doc in
                Attachment(id: doc.id) {
                    VisionRoomCard(doc: doc,
                                   isExpanded: expandedIDs.contains(doc.id),
                                   isSelected: selectedIDs.contains(doc.id))
                        .hoverEffect()
                }
            }
            // Wrist buttons — one per arm.
            Attachment(id: "arm:toggle:l") {
                VisionArmToggleButton(label: "Show", isExpanded: menuLeftExpanded)
            }
            Attachment(id: "arm:toggle:r") {
                VisionArmToggleButton(label: "Select", isExpanded: menuRightExpanded)
            }
            // Left arm chips: dim when that type is hidden.
            ForEach(VisionArmMenu.filters) { spec in
                Attachment(id: spec.id) {
                    VisionFilterChip(spec: spec, isHidden: hiddenTypeGroups.contains(spec.id))
                }
            }
            // Right arm: dim chips whose type has no selected documents.
            ForEach(VisionArmMenu.filters) { spec in
                Attachment(id: "r:" + spec.id) {
                    let typeSelected = roomModel.docs.contains { doc in
                        let tk = doc.documentType ?? (doc.wraps != nil ? "external" : "note")
                        return spec.types.contains(tk) && selectedIDs.contains(doc.id)
                    }
                    let isDimmed = !selectedIDs.isEmpty && !typeSelected
                    VisionFilterChip(spec: spec, isHidden: isDimmed)
                }
            }
            // Right arm: Settings button along the forearm.
            Attachment(id: "arm:settings:r") {
                VisionArmSettingsButton()
            }
        }
        .task {
            // One shared session for both arms avoids competing session conflicts.
            // Stored in @State so it is retained for the view's lifetime —
            // a local var is released when the task body exits, which stops
            // hand-joint tracking and leaves the anchors at world origin.
            let session = SpatialTrackingSession()
            trackingSession = session
            _ = await session.run(SpatialTrackingSession.Configuration(tracking: [.hand]))
            armMenuLeft.enableButton()
            armMenuRight.enableButton()
        }
        // Tap: look at a card + pinch once → expand/collapse.
        // Handled here at the entity level because the host's InputTargetComponent
        // captures the pinch before SwiftUI's onTapGesture in the attachment can fire.
        .simultaneousGesture(
            TapGesture()
                .targetedToAnyEntity()
                .onEnded { value in
                    // 1. Left torus: open / close the filter chip ring.
                    if armMenuLeft.isToggle(value.entity) {
                        armMenuLeft.toggleMenu()
                        menuLeftExpanded = armMenuLeft.isMenuExpanded
                        return
                    }
                    // 2. Right torus: open / close the solo chip ring.
                    if armMenuRight.isToggle(value.entity) {
                        armMenuRight.toggleMenu()
                        menuRightExpanded = armMenuRight.isMenuExpanded
                        return
                    }
                    // 3. Left arm chip — toggle that type's visibility, then close.
                    if let specID = armMenuLeft.specID(for: value.entity) {
                        if hiddenTypeGroups.contains(specID) {
                            hiddenTypeGroups.remove(specID)
                        } else {
                            hiddenTypeGroups.insert(specID)
                        }
                        armMenuLeft.collapseMenu()
                        menuLeftExpanded = armMenuLeft.isMenuExpanded
                        return
                    }
                    // 4. Right arm chip — toggle-select all docs of that type for group move.
                    if let specID = armMenuRight.specID(for: value.entity) {
                        guard let spec = VisionArmMenu.filters.first(where: { $0.id == specID }) else { return }
                        let typeIDs = roomModel.docs.compactMap { doc -> String? in
                            let tk = doc.documentType ?? (doc.wraps != nil ? "external" : "note")
                            return spec.types.contains(tk) ? doc.id : nil
                        }
                        // If all of this type are already selected, deselect; otherwise select all.
                        if typeIDs.allSatisfy({ selectedIDs.contains($0) }) {
                            typeIDs.forEach { selectedIDs.remove($0) }
                        } else {
                            typeIDs.forEach { selectedIDs.insert($0) }
                        }
                        armMenuRight.collapseMenu()
                        menuRightExpanded = armMenuRight.isMenuExpanded
                        return
                    }
                    // 5. Settings button — open the folder-picker window.
                    if armMenuRight.isSettings(value.entity) {
                        openWindow(id: "VisionSettings")
                        return
                    }
                    // 6. Document card: expand / collapse.
                    let host = value.entity
                    guard host.name.hasPrefix(Self.hostPrefix) else { return }
                    let id = String(host.name.dropFirst(Self.hostPrefix.count))
                    withAnimation(.spring(duration: 0.22)) {
                        if expandedIDs.contains(id) {
                            expandedIDs.remove(id)
                        } else {
                            expandedIDs.insert(id)
                        }
                    }
                }
        )
        // Drag: look at a card + pinch + move hand anywhere in the room.
        // value.location3D in scene space gives world metres —
        // translation3D is in SwiftUI points and must NOT be used directly.
        // A grab offset on the first frame keeps the card under your hand.
        .simultaneousGesture(
            DragGesture()
                .targetedToAnyEntity()
                .onChanged { value in
                    let host = value.entity
                    guard host.name.hasPrefix(Self.hostPrefix) else { return }
                    let id = String(host.name.dropFirst(Self.hostPrefix.count))
                    let oid = ObjectIdentifier(host)

                    let g = value.convert(value.location3D, from: .local, to: .scene)
                    let grab = SIMD3<Float>(Float(g.x), Float(g.y), Float(g.z))

                    let isGroupDrag = selectedIDs.contains(id) && selectedIDs.count > 1

                    if dragOffsets[oid] == nil {
                        dragOffsets[oid] = host.position(relativeTo: nil) - grab
                        if isGroupDrag {
                            groupDragAnchorStart = host.position(relativeTo: nil)
                            for selID in selectedIDs {
                                groupDragStartPositions[selID] = positions[selID]
                            }
                        }
                    }
                    guard let offset = dragOffsets[oid] else { return }
                    let newPos = grab + offset
                    host.setPosition(newPos, relativeTo: nil)
                    positions[id] = newPos

                    // Move all other selected cards by the same delta.
                    if isGroupDrag, let anchorStart = groupDragAnchorStart {
                        let delta = newPos - anchorStart
                        for selID in selectedIDs where selID != id {
                            guard let startPos = groupDragStartPositions[selID] else { continue }
                            let newSelPos = startPos + delta
                            positions[selID] = newSelPos
                            entityByID[selID]?.setPosition(newSelPos, relativeTo: nil)
                        }
                    }
                }
                .onEnded { value in
                    dragOffsets[ObjectIdentifier(value.entity)] = nil
                    groupDragAnchorStart = nil
                    groupDragStartPositions.removeAll()
                    savePositions()
                }
        )
        .onAppear { loadPositions() }
        .onDisappear { savePositions() }
        .onChange(of: roomModel.docs.count) {
            for (index, doc) in roomModel.docs.enumerated() where positions[doc.id] == nil {
                positions[doc.id] = seedPosition(index: index, total: roomModel.docs.count)
            }
            revision += 1
        }
    }

    // MARK: Layout

    /// Creates or updates the host + attachment pair for each document.
    /// Existing hosts are reused so positions don't reset on refresh.
    private func placeCards(root: Entity, attachments: RealityViewAttachments) {
        var keptNames = Set<String>()

        for (index, doc) in visibleDocs.enumerated() {
            let hostName = Self.hostPrefix + doc.id
            keptNames.insert(hostName)

            let host: Entity
            if let existing = root.findEntity(named: hostName) {
                host = existing
                // Re-adopt the attachment if RealityKit replaced it when the
                // SwiftUI card view changed (expand/collapse changes card bounds).
                let attachName = Self.attachPrefix + doc.id
                if existing.findEntity(named: attachName) == nil,
                   let attachment = attachments.entity(for: doc.id) {
                    attachment.name = attachName
                    existing.addChild(attachment)
                }
            } else {
                let modelHost = ModelEntity()
                modelHost.name = hostName
                // Collision box sized to a typical card (~24 × 14 cm, 1 cm deep).
                // .trigger mode so cards don't block each other physically.
                modelHost.components.set(CollisionComponent(
                    shapes: [.generateBox(width: 0.24, height: 0.14, depth: 0.01)],
                    mode: .trigger,
                    filter: .sensor
                ))
                // indirect = eye-gaze + pinch (the standard Vision Pro input mode).
                modelHost.components.set(InputTargetComponent(allowedInputTypes: .indirect))
                modelHost.components.set(BillboardComponent())
                root.addChild(modelHost)
                host = modelHost

                if let attachment = attachments.entity(for: doc.id) {
                    attachment.name = Self.attachPrefix + doc.id
                    host.addChild(attachment)
                }
            }

            host.position = positions[doc.id] ?? seedPosition(index: index, total: roomModel.docs.count)
            entityByID[doc.id] = host
        }

        // Only remove doc-host entities; leave arm-menu anchor entities in place.
        for child in Array(root.children)
        where child.name.hasPrefix(Self.hostPrefix) && !keptNames.contains(child.name) {
            child.removeFromParent()
        }
    }

    // MARK: Positions

    private var positionsKey: String? {
        roomModel.folderURL.map { "visionRoomPositions:" + $0.path }
    }

    private func loadPositions() {
        let docs = roomModel.docs
        if let key = positionsKey,
           let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: [Float]] {
            for (id, xyz) in stored where xyz.count == 3 {
                positions[id] = SIMD3(xyz[0], xyz[1], xyz[2])
            }
        }
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

    /// Fibonacci-sphere seed around the viewer, biased forward.
    /// Range: 1.0–1.9 m out, 0.9–2.1 m high.
    private func seedPosition(index: Int, total: Int) -> SIMD3<Float> {
        let goldenAngle = Float.pi * (3.0 - sqrt(5.0))
        let theta = goldenAngle * Float(index)
        let t = total > 1 ? Float(index) / Float(total - 1) : 0.5
        let y = 0.9 + t * 1.2
        let r = 1.0 + Float(index % 4) * 0.3
        return SIMD3(r * cos(theta), y, -abs(r * sin(theta)) - 0.5)
    }
}

// MARK: - Model

/// Scans the community folder for all .liquid.json documents and holds the
/// display list. No author filter — every document in the folder appears,
/// the same set the macOS app shows.
@MainActor @Observable
final class VisionRoomModel {
    private(set) var docs: [LiquidDoc] = []
    private(set) var folderURL: URL?
    private(set) var isScanning = false

    private var accessedURL: URL?

    func scan(folder: URL) {
        if let old = accessedURL, old != folder {
            old.stopAccessingSecurityScopedResource()
            accessedURL = nil
        }
        if accessedURL == nil && folder.startAccessingSecurityScopedResource() {
            accessedURL = folder
        }
        folderURL = folder
        isScanning = true
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                Self.readFolder(folder, cap: 100)
            }.value
            docs = found
            isScanning = false
        }
    }

    nonisolated private static func readFolder(_ folder: URL, cap: Int) -> [LiquidDoc] {
        var result: [LiquidDoc] = []
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey,
                                         .ubiquitousItemDownloadingStatusKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        for case let url as URL in enumerator {
            guard LiquidDoc.isDocumentFile(url) else { continue }
            // Skip dataless iCloud placeholders — reading them would block.
            if let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                .ubiquitousItemDownloadingStatus,
               status == .notDownloaded { continue }
            guard let data = try? Data(contentsOf: url),
                  let doc = try? LiquidDoc.decode(data: data, fileURL: url),
                  !doc.draft
            else { continue }
            result.append(doc)
            if result.count >= cap { break }
        }
        return result.sorted { $0.listedDate > $1.listedDate }
    }
}

// MARK: - Card

/// A floating document card. Expanded state is owned by VisionRoomSpaceView;
/// tap handling lives there too (entity-level TapGesture) because the host
/// entity's InputTargetComponent intercepts the pinch before SwiftUI can.
struct VisionRoomCard: View {
    let doc: LiquidDoc
    let isExpanded: Bool
    var isSelected: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {

            Label(displayType, systemImage: typeIcon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(typeColor)
                .textCase(.uppercase)

            Text(doc.title)
                .font(.system(size: 14, weight: .semibold, design: .serif))
                .foregroundStyle(.primary)
                .lineLimit(isExpanded ? 4 : 2)

            if isExpanded, let excerpt = bodyExcerpt {
                Text(excerpt)
                    .font(.system(size: 11, design: .serif))
                    .foregroundStyle(.secondary)
                    .lineLimit(10)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 2)
            }

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
        .frame(minWidth: 150, maxWidth: isExpanded ? 300 : 210)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(isExpanded
                      ? AnyShapeStyle(Color(white: 0.14))
                      : AnyShapeStyle(.regularMaterial))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            isSelected
                                ? AnyShapeStyle(Color.white.opacity(0.9))
                                : AnyShapeStyle(typeColor.opacity(isExpanded ? 0.55 : 0.3)),
                            lineWidth: isSelected ? 2.5 : 1
                        )
                )
        }
        .shadow(color: isSelected ? typeColor.opacity(0.5) : .clear, radius: 8)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 12))
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

// MARK: - Settings window

/// Folder picker for the shared community folder, presented as a small
/// floating window from the Settings button on the right wrist.
struct VisionSettingsView: View {
    @Environment(NotesModel.self) private var notes
    @Environment(VisionRoomModel.self) private var roomModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var choosingFolder = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.title2.weight(.semibold))
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Shared Folder")
                    .font(.headline)
                if let url = notes.folderURL {
                    Text(url.lastPathComponent)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    Text("No folder chosen")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                Button("Choose Folder…") { choosingFolder = true }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 300)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                notes.openFolder(url)
                roomModel.scan(folder: url)
                dismissWindow(id: "VisionSettings")
            }
        }
    }
}

#endif
