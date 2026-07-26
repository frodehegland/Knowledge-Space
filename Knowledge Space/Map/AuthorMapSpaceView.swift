//
//  AuthorMapSpaceView.swift
//  Knowledge Space
//
//  The Map as the original Author visionOS Map had it: an immersive
//  space where concept cards hang free in the room — nothing frames or
//  crops them — joined by threads and worked directly by hand. A tap
//  selects, a double tap unfolds the definition, a drag moves the
//  selection together. The control bar lives in its own window
//  (MapControlsView), moving independently of the map.
//
//  Cards are RealityKit attachment entities, not views on a canvas, so
//  there is no bound on how wide, tall, or deep a card can go.
//

#if os(visionOS)
import SwiftUI
import RealityKit

struct AuthorMapSpaceView: View {
    @Environment(AuthorMapState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    /// Drag anchors for every card the current gesture is moving.
    @State private var dragStarts: [String: NodePosition] = [:]

    /// The original Map's manners, under the original names: only
    /// selected cards answer the hand, and the selection moves as one.
    @AppStorage("onlySelectedNodesCanMove") private var onlySelectedNodesCanMove = true
    @AppStorage("allSelectedNodesMoveTogether") private var allSelectedNodesMoveTogether = true

    /// Billboarding turns every card toward the viewer. Off, cards hang
    /// fixed and each carries a reversed twin, so from behind the text
    /// still reads the right way around.
    @AppStorage("nodeBillboarding") private var nodeBillboarding = true

    /// One meter in points where the map hangs, so drag translations in
    /// view points convert back to map coordinates — the original's
    /// 1000 canvas points to the meter.
    @PhysicalMetric(from: .meters) private var meter = 1.0

    /// The map anchor's place in the room — the original's [0, 1.4, −1.4]:
    /// eye height, an arm-and-a-half ahead of where the space opened.
    private static let anchor = SIMD3<Float>(0, 1.4, -1.4)

    private static let rootName = "MapRoot"

    var body: some View {
        RealityView { content, attachments in
            let root = Entity()
            root.name = Self.rootName
            root.position = Self.anchor
            content.add(root)
            layout(root: root, attachments: attachments)
            placeBangles(content: content, attachments: attachments)
        } update: { content, attachments in
            if let root = content.entities.first(where: { $0.name == Self.rootName }) {
                layout(root: root, attachments: attachments)
            }
            placeBangles(content: content, attachments: attachments)
        } attachments: {
            ForEach(visibleNodes, id: \.identifier) { node in
                Attachment(id: node.identifier) {
                    AuthorMapNodeCard(node: node,
                                      tag: state.engine.effectiveTag(of: node),
                                      isSelected: state.engine.selection.contains(node.identifier),
                                      isExpanded: state.expandedNodes.contains(node.identifier))
                        .hoverEffect()
                        .gesture(drag(for: node.identifier))
                        .gesture(ExclusiveGesture(
                            TapGesture(count: 2).onEnded {
                                state.toggleExpanded(node.identifier)
                            },
                            TapGesture(count: 1).onEnded {
                                state.toggleSelection(of: node.identifier)
                            }
                        ))
                }
            }
            // With billboarding off, each card's reversed twin — the
            // same card, view-only, facing the other way.
            if !nodeBillboarding {
                ForEach(visibleNodes, id: \.identifier) { node in
                    Attachment(id: node.identifier + ":back") {
                        AuthorMapNodeCard(node: node,
                                          tag: state.engine.effectiveTag(of: node),
                                          isSelected: state.engine.selection.contains(node.identifier),
                                          isExpanded: state.expandedNodes.contains(node.identifier))
                    }
                }
            }
            Attachment(id: Self.leftBangleID) {
                MapBangle(systemImage: "slider.horizontal.3", action: toggleControls)
            }
            Attachment(id: Self.rightBangleID) {
                MapBangle(systemImage: "gearshape", action: toggleSettings)
            }
        }
        .onAppear {
            state.pointsPerMeter = meter
            state.isMapSpaceOpen = true
        }
        .onDisappear {
            state.isMapSpaceOpen = false
            if state.hasUnsavedChanges {
                state.save()
            }
        }
        .onChange(of: meter) {
            state.pointsPerMeter = meter
        }
    }

    // MARK: - Nodes

    private var visibleNodes: [FlowNode] {
        _ = state.revision
        return state.spaceNodes
            .sorted { $0.identifier < $1.identifier }
    }

    /// A node's place in the room, in meters around the map anchor.
    /// RealityKit's y runs up where the map's runs down, so y flips.
    private func roomPosition(of node: FlowNode) -> SIMD3<Float> {
        let p = state.viewPosition(of: node)
        let ppm = max(state.pointsPerMeter, 1)
        return SIMD3(Float(p.x / ppm), Float(-p.y / ppm), Float(p.z / ppm))
    }

    // MARK: - Entities

    /// Lays the whole map out under the root: every visible card's
    /// attachment entity at its place in the room, one thread entity per
    /// visible connection, and everything that left the map swept away.
    private func layout(root: Entity, attachments: RealityViewAttachments) {
        _ = state.revision
        let nodes = visibleNodes
        let visible = Dictionary(uniqueKeysWithValues: nodes.map { ($0.identifier, $0) })
        // Kept by identity, not name: toggling billboarding hands back
        // fresh attachment entities under the old names, and a name
        // sweep would keep the stale twin alongside the new one.
        var kept: Set<ObjectIdentifier> = []

        for node in nodes {
            guard let card = attachments.entity(for: node.identifier) else { continue }
            card.name = "card:" + node.identifier
            kept.insert(ObjectIdentifier(card))
            if card.parent !== root {
                root.addChild(card)
            }
            // Billboarding turns the card toward the viewer from
            // wherever they stand; without it the card hangs fixed and
            // its reversed twin carries the text for viewers behind.
            if nodeBillboarding {
                card.components.set(BillboardComponent())
            } else {
                card.components.remove(BillboardComponent.self)
            }
            card.position = roomPosition(of: node)

            if !nodeBillboarding,
               let back = attachments.entity(for: node.identifier + ":back") {
                back.name = "cardback:" + node.identifier
                kept.insert(ObjectIdentifier(back))
                if back.parent !== root {
                    root.addChild(back)
                }
                // A hair behind the front face, turned to look the
                // other way.
                back.position = roomPosition(of: node) + SIMD3(0, 0, -0.002)
                back.orientation = simd_quatf(angle: .pi, axis: SIMD3(0, 1, 0))
            }
        }

        // Threads only show around the selection; an unselected map
        // hangs quiet, without the whole web of lines behind it.
        let selection = state.engine.selection
        for connection in state.engine.document.connections {
            guard let from = visible[connection.startNodeIdentifier],
                  let to = visible[connection.endingNodeIdentifier],
                  selection.contains(from.identifier) || selection.contains(to.identifier)
            else { continue }
            // The thread runs card edge to card edge, never through a
            // note: each end pulls back to where it leaves its card.
            guard let (start, end) = trimmedSegment(
                from: roomPosition(of: from), to: roomPosition(of: to),
                startCard: attachments.entity(for: from.identifier),
                endingCard: attachments.entity(for: to.identifier),
                root: root)
            else { continue }
            if let thread = placeThread(named: "thread:" + connection.identifier,
                                        in: root, from: start, to: end) {
                kept.insert(ObjectIdentifier(thread))
            }
        }

        for child in Array(root.children) where !kept.contains(ObjectIdentifier(child)) {
            child.removeFromParent()
        }
    }

    // MARK: - Bangles

    private static let leftBangleID = "bangle.left"
    private static let rightBangleID = "bangle.right"

    /// One bangle on the back of each wrist, worn like a watch face:
    /// left toggles the toolbar, right toggles the settings panel.
    private func placeBangles(content: RealityViewContent, attachments: RealityViewAttachments) {
        let bangles: [(String, AnchoringComponent.Target.Chirality)] = [
            (Self.leftBangleID, .left),
            (Self.rightBangleID, .right)
        ]
        for (id, chirality) in bangles {
            guard content.entities.first(where: { $0.name == "anchor:" + id }) == nil,
                  let bangle = attachments.entity(for: id) else { continue }
            let anchor = AnchorEntity(.hand(chirality, location: .wrist))
            anchor.name = "anchor:" + id
            // The wrist anchor's y points out of the back of the hand;
            // the attachment faces +z, so lay it onto the wrist.
            bangle.orientation = simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0))
            bangle.position = SIMD3(0, 0.02, 0)
            anchor.addChild(bangle)
            content.add(anchor)
        }
    }

    private func toggleControls() {
        if state.isControlsWindowOpen {
            // The one sanctioned way to put the toolbar away; without
            // this flag it reopens itself.
            state.controlsToggledOff = true
            dismissWindow(id: "MapControls")
        } else {
            openWindow(id: "MapControls")
        }
    }

    private func toggleSettings() {
        if state.isSettingsWindowOpen {
            dismissWindow(id: "MapSettings")
        } else {
            openWindow(id: "MapSettings")
        }
    }

    // MARK: - Threads

    /// A unit thread: a cylinder one meter long and one across, standing
    /// along y, scaled and turned per connection.
    private static let threadMesh = MeshResource.generateCylinder(height: 1, radius: 0.5)

    /// Pulls each end of a segment back to the edge of its card's
    /// rendered bounds, so no thread shows inside a note — only between
    /// them. Cards close enough to overlap get no thread at all.
    private func trimmedSegment(from a: SIMD3<Float>, to b: SIMD3<Float>,
                                startCard: Entity?, endingCard: Entity?,
                                root: Entity) -> (SIMD3<Float>, SIMD3<Float>)? {
        let d = b - a
        let length = simd_length(d)
        guard length > 0.001 else { return nil }
        let dir = d / length
        let tA = exitDistance(of: startCard, along: dir, root: root)
        let tB = exitDistance(of: endingCard, along: dir, root: root)
        guard tA + tB < length - 0.01 else { return nil }
        return (a + dir * tA, b - dir * tB)
    }

    /// How far a ray from a card's center runs before it leaves the
    /// card's bounding box.
    private func exitDistance(of card: Entity?, along dir: SIMD3<Float>, root: Entity) -> Float {
        guard let card else { return 0 }
        let half = card.visualBounds(relativeTo: root).extents / 2
        var t = Float.greatestFiniteMagnitude
        for i in 0..<3 where abs(dir[i]) > 0.0001 {
            t = min(t, half[i] / abs(dir[i]))
        }
        return t.isFinite ? max(t, 0) : 0
    }

    /// Puts one thread where it belongs: at the segment's midpoint,
    /// scaled to its length and weight, rotated so its axis carries
    /// a → b.
    private func placeThread(named name: String, in root: Entity,
                             from a: SIMD3<Float>, to b: SIMD3<Float>) -> Entity? {
        let d = b - a
        let length = simd_length(d)
        guard length > 0.001 else { return nil }

        let thread: ModelEntity
        if let existing = root.findEntity(named: name) as? ModelEntity {
            thread = existing
        } else {
            thread = ModelEntity(mesh: Self.threadMesh,
                                 materials: [UnlitMaterial(color: .white)])
            thread.name = name
            root.addChild(thread)
        }

        thread.position = (a + b) / 2
        thread.orientation = Self.rotation(fromYAxisTo: d / length)
        let width: Float = 0.002
        thread.scale = SIMD3(width, length, width)
        thread.components.set(OpacityComponent(opacity: 0.5))
        return thread
    }

    /// Turns the unit cylinder's y-axis onto the segment's direction;
    /// straight down is the one direction simd_quatf(from:to:) can't make.
    private static func rotation(fromYAxisTo axis: SIMD3<Float>) -> simd_quatf {
        let y = SIMD3<Float>(0, 1, 0)
        if simd_dot(y, axis) < -0.9999 {
            return simd_quatf(angle: .pi, axis: SIMD3(1, 0, 0))
        }
        return simd_quatf(from: y, to: axis)
    }

    // MARK: - Direct manipulation

    /// The original's move: the same pinch carries a card across the
    /// plane and pulls or pushes it in depth. Only selected cards move
    /// (when the setting says so), and the whole selection moves as one.
    /// Live movement bypasses undo; release commits one undoable move.
    private func drag(for id: String) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let isSelected = state.engine.selection.contains(id)
                if onlySelectedNodesCanMove && !isSelected {
                    return
                }
                if dragStarts.isEmpty {
                    var moving: Set<String> = [id]
                    if allSelectedNodesMoveTogether && isSelected {
                        moving.formUnion(state.engine.selection)
                    }
                    for movingID in moving {
                        dragStarts[movingID] = state.engine.position(of: movingID)
                    }
                }
                let delta = SIMD3(value.translation3D.x,
                                  value.translation3D.y,
                                  value.translation3D.z)
                for (movingID, start) in dragStarts {
                    state.drag(node: movingID, from: start, viewDelta: delta)
                }
            }
            .onEnded { _ in
                state.endDrag(nodes: dragStarts)
                dragStarts = [:]
            }
    }
}

// MARK: - Bangle

/// A bangle: a small round control worn on the wrist.
struct MapBangle: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .glassBackgroundEffect(in: .circle)
        .hoverEffect()
    }
}

// MARK: - Node card

struct AuthorMapNodeCard: View {
    let node: FlowNode
    let tag: String
    let isSelected: Bool
    let isExpanded: Bool

    // Appearance settings (the Settings window's Appearance tab).
    @AppStorage("nodeBorderVisible") private var nodeBorderVisible = true
    @AppStorage("nodeMaxCharsClosed") private var nodeMaxCharsClosed = 30
    @AppStorage("nodeMaxCharsOpen") private var nodeMaxCharsOpen = 45
    @AppStorage("nodeOpaqueWhenOpen") private var nodeOpaqueWhenOpen = true
    @AppStorage("nodeOpaqueWhenSelected") private var nodeOpaqueWhenSelected = true

    /// Solid ground when open or selected, as the settings allow.
    private var isOpaque: Bool {
        (isExpanded && nodeOpaqueWhenOpen) || (isSelected && nodeOpaqueWhenSelected)
    }

    /// The settings speak in characters; an average character of the
    /// 15 pt serif title runs about half an em, so 7.5 points each.
    private var maxCardWidth: CGFloat {
        let chars = isExpanded && node.definition?.isEmpty == false
            ? nodeMaxCharsOpen : nodeMaxCharsClosed
        return CGFloat(max(chars, 8)) * 7.5
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(node.name)
                .font(.system(size: 15, weight: node.type == .citation ? .regular : .semibold, design: .serif))
                .strikethrough(node.isStruckthrough)
                .lineLimit(3)
            // The tag names the card's kind — except "concept" and
            // "note", which the card's look already carries.
            if tag != "concept" && tag != "note" {
                Text(tag)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(tagColor)
                    .textCase(.uppercase)
            }
            // The definition unfolds on the original's double tap — the
            // card is the knowledge, not just a label for it.
            if isExpanded, let definition = node.definition, !definition.isEmpty {
                Text(definition)
                    .font(.system(size: 12, design: .serif))
                    .foregroundStyle(.secondary)
                    .lineLimit(12)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 4)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minWidth: 90, maxWidth: maxCardWidth)
        // A material clipped to the same shape as the border, so the
        // background's corners curve with it (glass in the open space
        // ignored the rounding). Open cards go opaque so the definition
        // reads against solid ground; closed ones let the room through.
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(isOpaque ? AnyShapeStyle(Color(white: 0.16)) : AnyShapeStyle(.regularMaterial))
        }
        // The border can be switched off in Appearance settings; the
        // selection stroke stays regardless, or selection would go mute.
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isSelected ? Color.accentColor : tagColor.opacity(nodeBorderVisible ? 0.35 : 0),
                              lineWidth: isSelected ? 2.5 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 14))
        .opacity(node.isHidden ? 0.4 : 1)
    }

    private var tagColor: Color {
        switch tag {
        case "person": return .orange
        case "location": return .green
        case "institution": return .teal
        case "event": return .purple
        case "issue": return .red
        case "in progress": return .blue
        case "done": return .mint
        case "reference": return .indigo
        case "note": return .yellow
        case "section": return .brown
        default: return node.type == .citation ? .cyan : .white
        }
    }
}
#endif
