//
//  AuthorMapSpaceView.swift
//  Knowledge Space
//
//  The Author Map as a volume: every node a card, connections as threads
//  through all three dimensions. Positions come from the document's own
//  layout (Author's x/y, extended into z here) — not a per-view store —
//  so the arrangement is the document's, shared with the Mac, and the AI
//  agent moves the same nodes the hand does. Cards move on x/y/z and
//  never rotate.
//
//  Rendering follows the house techniques from SpatialCardPlane (3D drag
//  via translation3D, capsule threads rotated through the volume).
//

#if os(visionOS)
import SwiftUI
import UniformTypeIdentifiers

struct AuthorMapSpaceView: View {
    @State private var state = AuthorMapState()
    @State private var dragStarts: [String: NodePosition] = [:]
    @State private var showingImporter = false
    @State private var showingAgentPanel = true

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                threads(in: geometry.size)
                nodeCards(in: geometry.size)
            }
            .onChange(of: state.documentURL) {
                state.fit(in: geometry.size)
            }
            .onAppear {
                state.reopenLastDocument()
                state.fit(in: geometry.size)
            }
        }
        .overlay {
            if state.documentURL == nil {
                ContentUnavailableView {
                    Label("Author Map", systemImage: "circle.hexagongrid")
                } description: {
                    Text("Open an Author document (.liquid) to see its Map in space.")
                } actions: {
                    Button("Open Document…") { showingImporter = true }
                }
            }
        }
        .ornament(attachmentAnchor: .scene(.bottom)) { controls }
        .ornament(attachmentAnchor: .scene(.trailing)) {
            if showingAgentPanel && state.documentURL != nil {
                AuthorMapAgentPanel(state: state)
            }
        }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: openableTypes,
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                state.open(url: url)
            }
        }
    }

    private var openableTypes: [UTType] {
        var types: [UTType] = [.package, .folder]
        if let liquid = UTType(filenameExtension: "liquid", conformingTo: .package) {
            types.insert(liquid, at: 0)
        }
        return types
    }

    // MARK: - Nodes

    private var visibleNodes: [FlowNode] {
        _ = state.revision
        return state.engine.visibleNodes
            .sorted { $0.identifier < $1.identifier }
    }

    private func nodeCards(in size: CGSize) -> some View {
        ForEach(visibleNodes, id: \.identifier) { node in
            let p = state.viewPosition(of: node, in: size)
            AuthorMapNodeCard(node: node,
                              tag: state.engine.effectiveTag(of: node),
                              isSelected: state.engine.selection.contains(node.identifier))
                .hoverEffect()
                .position(x: p.x, y: p.y)
                .offset(z: p.z)
                .gesture(drag(for: node.identifier))
                .onTapGesture { state.toggleSelection(of: node.identifier) }
        }
    }

    /// The same pinch moves a card on the plane and pulls or pushes it in
    /// z. Live movement bypasses undo; release commits one undoable move.
    private func drag(for id: String) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = dragStarts[id] ?? state.engine.position(of: id)
                if dragStarts[id] == nil { dragStarts[id] = start }
                state.drag(node: id,
                           from: start,
                           viewDelta: SIMD3(value.translation3D.x,
                                            value.translation3D.y,
                                            value.translation3D.z))
            }
            .onEnded { _ in
                if let start = dragStarts[id] {
                    state.endDrag(node: id, from: start)
                }
                dragStarts[id] = nil
            }
    }

    // MARK: - Threads

    private struct Thread: Identifiable {
        let id: String
        let from: SIMD3<Double>
        let to: SIMD3<Double>
        let lit: Bool
    }

    private func threads(in size: CGSize) -> some View {
        _ = state.revision
        let engine = state.engine
        let visible = Dictionary(uniqueKeysWithValues: visibleNodes.map { ($0.identifier, $0) })
        let selection = engine.selection

        let items: [Thread] = engine.document.connections.compactMap { connection in
            guard let from = visible[connection.startNodeIdentifier],
                  let to = visible[connection.endingNodeIdentifier] else { return nil }
            let lit = selection.contains(from.identifier) || selection.contains(to.identifier)
            return Thread(id: connection.identifier,
                          from: state.viewPosition(of: from, in: size),
                          to: state.viewPosition(of: to, in: size),
                          lit: lit)
        }

        return ForEach(items) { thread in
            threadCapsule(from: thread.from, to: thread.to,
                          opacity: thread.lit ? 0.9 : 0.25,
                          width: thread.lit ? 2 : 1.2)
        }
    }

    /// One thread: a capsule of the segment's true 3D length, laid along
    /// the x-axis, rotated so its x-axis carries a → b, placed at the
    /// midpoint (the SpatialCardPlane construction).
    @ViewBuilder
    private func threadCapsule(from pa: SIMD3<Double>, to pb: SIMD3<Double>,
                               opacity: Double, width: Double) -> some View {
        let d = pb - pa
        let length = (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()
        if length > 1 {
            let u = d / length
            let angle = acos(max(-1, min(1, u.x)))
            let raw = SIMD3<Double>(0, -u.z, u.y)
            let axisLength = (raw.y * raw.y + raw.z * raw.z).squareRoot()
            let axis = axisLength > 1e-6 ? raw / axisLength : SIMD3<Double>(0, 1, 0)
            Capsule()
                .fill(Color.white.opacity(opacity))
                .frame(width: length, height: max(width, 1))
                .rotation3DEffect(.radians(angle), axis: (x: axis.x, y: axis.y, z: axis.z))
                .position(x: (pa.x + pb.x) / 2, y: (pa.y + pb.y) / 2)
                .offset(z: (pa.z + pb.z) / 2)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 12) {
            if state.documentURL != nil {
                Text(state.documentTitle)
                    .foregroundStyle(.secondary)

                selectMenu
                showMenu
                arrangeMenu

                Button {
                    state.run(.setSelection(ids: []))
                    if state.engine.canUndo {
                        try? state.engine.undo()
                    }
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!state.engine.canUndo)
                .labelStyle(.iconOnly)

                Button {
                    state.save()
                } label: {
                    Label("Save", systemImage: state.hasUnsavedChanges ? "circle.fill" : "checkmark.circle")
                }

                Button {
                    showingAgentPanel.toggle()
                } label: {
                    Label("Assistant", systemImage: "sparkles")
                }
            }

            Button {
                showingImporter = true
            } label: {
                Label("Open…", systemImage: "folder")
            }
        }
        .padding(10)
        .glassBackgroundEffect()
    }

    private var selectMenu: some View {
        Menu {
            Button("All") { state.run(.selectAll) }
            Button("None") { state.run(.deselectAll) }
            Divider()
            ForEach(Self.commonTags, id: \.self) { tag in
                Button(tag.capitalized) {
                    state.run(.selectByCriteria(criteria: MapCriteria(tagIdentifiers: [tag]), extending: false))
                }
            }
            Divider()
            Button("Similar") { state.run(.selectSimilar) }
            Button("Connected") { state.run(.selectConnected) }
        } label: {
            Label("Select", systemImage: "circle.dashed")
        }
    }

    private var showMenu: some View {
        Menu {
            Button("Concepts and Citations") { state.run(.setVisibilityMode(.showConceptsAndCitations)) }
            Button("Only Concepts") { state.run(.setVisibilityMode(.showOnlyConcepts)) }
            Button("Only Citations") { state.run(.setVisibilityMode(.showOnlyCitations)) }
            Button("Only Notes") { state.run(.setVisibilityMode(.showOnlyNotes)) }
            Button("Everything") { state.run(.setVisibilityMode(.showAll)) }
            Divider()
            Button("Hide Selected") {
                state.run(.toggleHiddenForSelection)
            }
        } label: {
            Label("Show", systemImage: "eye")
        }
    }

    private var arrangeMenu: some View {
        Menu {
            Menu("Align") {
                Button("Left Edges") { state.run(.align(axis: .x, alignment: .minEdge)) }
                Button("Horizontal Centers") { state.run(.align(axis: .x, alignment: .center)) }
                Button("Right Edges") { state.run(.align(axis: .x, alignment: .maxEdge)) }
                Divider()
                Button("Top Edges") { state.run(.align(axis: .y, alignment: .minEdge)) }
                Button("Vertical Centers") { state.run(.align(axis: .y, alignment: .center)) }
                Button("Bottom Edges") { state.run(.align(axis: .y, alignment: .maxEdge)) }
                Divider()
                Button("Same Depth") { state.run(.align(axis: .z, alignment: .center)) }
            }
            Menu("Distribute") {
                Button("Horizontally") { state.run(.distribute(axis: .x, sort: .standard, style: .evenly)) }
                Button("Vertically") { state.run(.distribute(axis: .y, sort: .standard, style: .evenly)) }
                Button("In Depth") { state.run(.distribute(axis: .z, sort: .standard, style: .evenly)) }
                Divider()
                Button("Alphabetically") { state.run(.distribute(axis: .x, sort: .alphabetic, style: .spacing)) }
                Button("By Time") { state.run(.distribute(axis: .x, sort: .time, style: .spacing)) }
            }
            Button("Flatten to Plane") {
                let ids = state.engine.document.nodes.map { $0.identifier }
                var positions: [FlowNodeIdentifier: NodePosition] = [:]
                for id in ids {
                    let p = state.engine.position(of: id)
                    positions[id] = NodePosition(x: p.x, y: p.y, z: 0)
                }
                state.run(.move(positions: positions))
            }
        } label: {
            Label("Arrange", systemImage: "square.grid.3x3")
        }
    }

    static let commonTags = ["concept", "person", "location", "institution", "event", "issue", "done", "marked", "reference", "note", "section"]
}

// MARK: - Node card

struct AuthorMapNodeCard: View {
    let node: FlowNode
    let tag: String
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            Text(node.name)
                .font(.system(size: 15, weight: node.type == .citation ? .regular : .semibold, design: .serif))
                .strikethrough(node.isStruckthrough)
                .lineLimit(3)
            if tag != "concept" {
                Text(tag)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(tagColor)
                    .textCase(.uppercase)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minWidth: 90, maxWidth: 220)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isSelected ? Color.accentColor : tagColor.opacity(0.35),
                              lineWidth: isSelected ? 2.5 : 1)
        )
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
