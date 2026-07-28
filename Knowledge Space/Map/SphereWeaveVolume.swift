//
//  SphereWeaveVolume.swift
//  Knowledge Space
//
//  The Sphere Weave for the room: an immersive space, not a boxed
//  volume. The reader stands near the center — documents on the inner
//  sphere just past arm's reach, people further out, places by the
//  walls. Pinch any node to make it the center and the threads
//  re-weave. A small control bar window carries the keyword field and
//  the way out, like the Map's own controls.
//
//  Everything here is plain geometry: dots are instanced spheres,
//  labels are text meshes, threads are one shared beam scaled to
//  length. On visionOS the compositor (backboardd) carries the render
//  cost of hover effects, SwiftUI attachments, and opacity groups —
//  an earlier build used all three across hundreds of nodes and
//  inflated the compositor until the system killed it, taking the
//  whole interface down. Geometry it stays.
//

#if os(visionOS)
import SwiftUI
import RealityKit

// MARK: - The space

struct SphereWeaveSpaceView: View {
    @Environment(AuthorMapState.self) private var state

    @State private var builder = WeaveVolumeBuilder()

    /// The woven shells, recomputed only when the center or the folder
    /// changes — computing in `body` would re-run the keyword search
    /// over every document on every update.
    @State private var woven = SphereWeaveView.SphereData()

    var body: some View {
        // The builder is fed only from onAppear/onChange below — never
        // from the make/update closures. Those closures capture `woven`
        // from whichever body evaluation created them, and a stale one
        // running late once wiped the freshly built shells back to
        // empty while the threads survived their unchanged key.
        RealityView { content in
            // The weave hangs centered a step ahead at chest height:
            // the inner document sphere wraps gently around the
            // reader, the outer shells fill the room.
            builder.root.position = [0, 1.35, -0.6]
            content.add(builder.root)
        }
        .gesture(TapGesture().targetedToAnyEntity().onEnded { value in
            recenter(from: value.entity)
        })
        .onAppear {
            state.isWeaveSpaceOpen = true
            // Opened before the Library window has run? The folder
            // bookmark restores the same way it does there.
            if state.folderURL == nil {
                state.reopenLastDocument()
            }
            reweave()
        }
        .onDisappear {
            state.isWeaveSpaceOpen = false
        }
        .onChange(of: state.weaveCenter) { reweave() }
        .onChange(of: state.weaveDocuments.count) { reweave() }
    }

    private func reweave() {
        woven = sphereData
        builder.apply(woven)
    }

    /// The shells and threads, woven from the Map's folder scan: the
    /// people are the credited authors, the backlinks inverted from
    /// the documents' own links.
    private var sphereData: SphereWeaveView.SphereData {
        #if targetEnvironment(simulator)
        // The simulator rarely has the community folder; weave a demo
        // library so the space can be seen and tuned without a device.
        if state.weaveDocuments.isEmpty {
            var data = SphereWeaveView.SphereData()
            data.documents = (1...120).map {
                .init(id: "doc:demo\($0)", label: "Demo note \($0)")
            }
            data.people = (1...8).map {
                .init(id: "person:Person \($0)", label: "Person \($0)")
            }
            data.places = ["London", "Oslo", "Palo Alto", "Wimbledon"].map {
                .init(id: "place:\($0)", label: $0)
            }
            data.centerID = "kw:hypertext"
            data.centerLabel = "“hypertext”"
            for index in stride(from: 2, through: 120, by: 3) {
                data.connected.insert("doc:demo\(index)")
            }
            data.connected.insert("person:Person 2")
            data.connected.insert("place:Oslo")
            return data
        }
        #endif
        // One document per id: the community folder can hold duplicate
        // ids (conflict copies), and every id here becomes an entity
        // name and a dictionary key.
        var seenIDs = Set<String>()
        let docs = state.weaveDocuments.suffix(500).filter {
            !$0.isDigest && seenIDs.insert($0.id).inserted
        }
        var seenPeople = Set<String>()
        var people: [String] = []
        for doc in docs {
            let name = doc.creditedAuthor
            guard !name.isEmpty,
                  seenPeople.insert(name.lowercased()).inserted else { continue }
            people.append(name)
        }
        var backlinks: [String: [String]] = [:]
        for doc in docs {
            for link in doc.links {
                backlinks[link.to, default: []].append(doc.id)
            }
        }
        return .woven(
            center: state.weaveCenter,
            docs: docs,
            people: people.sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            },
            backlinksTo: { backlinks[$0] ?? [] })
    }

    private func recenter(from entity: Entity) {
        var node: Entity? = entity
        while let candidate = node {
            let name = candidate.name
            if name.hasPrefix("doc:") {
                state.weaveCenter = .document(String(name.dropFirst(4)))
                return
            }
            if name.hasPrefix("person:") {
                state.weaveCenter = .person(String(name.dropFirst(7)))
                return
            }
            if name.hasPrefix("place:") {
                state.weaveCenter = .place(String(name.dropFirst(6)))
                return
            }
            node = candidate.parent
        }
    }
}

// MARK: - The controls

/// The weave's control bar, a small window like the Map's own: the
/// keyword field, the centered element's name, and the way out.
struct SphereWeaveControlsView: View {
    @Environment(AuthorMapState.self) private var state
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    @State private var keyword = "hypertext"

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "globe")
            TextField("Center on a keyword…", text: $keyword)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit {
                    let trimmed = keyword.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        state.weaveCenter = .keyword(trimmed)
                    }
                }
            Text(centerCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button {
                Task { @MainActor in
                    if state.isWeaveSpaceOpen {
                        await dismissImmersiveSpace()
                    }
                    openWindow(id: "Library")
                    dismissWindow(id: "SphereWeaveControls")
                }
            } label: {
                Label("Close Weave", systemImage: "xmark.circle")
            }
            .labelStyle(.iconOnly)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var centerCaption: String {
        switch state.weaveCenter {
        case .none:
            return "Nothing centered yet."
        case .keyword(let word):
            return "Centered on “\(word)”"
        case .document(let id):
            let title = state.weaveDocuments.first { $0.id == id }?.title ?? id
            return "Centered on “\(title)”"
        case .person(let name):
            return "Centered on \(name)"
        case .place(let name):
            return "Centered on \(name)"
        }
    }
}

// MARK: - The entities

/// Builds and maintains the weave's entities — three lattice shells,
/// the black center, the threads, the text-mesh labels: the RealityKit
/// twin of the Mac scene's coordinator, at room scale.
@MainActor
final class WeaveVolumeBuilder {
    let root = Entity()
    private let shells = Entity()
    private let threads = Entity()
    private var dots: [String: Entity] = [:]
    private var shellsKey = ""
    private var centerKey = ""

    /// The Mac scene's shell radii (7 / 11 / 15) mapped into the room:
    /// documents at 1.05 m — just past arm's reach around the reader —
    /// people at 1.65 m, places at 2.25 m, out by the walls.
    private static let metersPerUnit: Float = 0.15

    /// How many of each kind wear a name. Every label is a text mesh;
    /// a center word the whole library contains would otherwise grow
    /// hundreds of them.
    private static let labelCap = 60

    // Shell colors: documents ink-blue within, people green between,
    // places warm at the horizon — the Mac scene's palette.
    private static let documentColor = UIColor(red: 0.32, green: 0.42, blue: 0.62, alpha: 1)
    private static let personColor = UIColor(red: 0.29, green: 0.58, blue: 0.42, alpha: 1)
    private static let placeColor = UIColor(red: 0.74, green: 0.49, blue: 0.24, alpha: 1)

    func apply(_ data: SphereWeaveView.SphereData) {
        if shells.parent == nil { root.addChild(shells) }
        if threads.parent == nil { root.addChild(threads) }
        let newShellsKey = "\(data.documents.count)/\(data.people.count)/\(data.places.count)"
            + data.documents.map(\.id).joined()
        if shellsKey != newShellsKey {
            shellsKey = newShellsKey
            rebuildShells(data)
            centerKey = ""
        }
        let newCenterKey = data.centerID + data.connected.sorted().joined()
        if centerKey != newCenterKey {
            centerKey = newCenterKey
            rebuildThreads(data)
        }
    }

    /// The three shells, each node evenly spaced on its sphere by the
    /// Fibonacci lattice. People and places wear their names (capped);
    /// document names appear only when the center touches them.
    private func rebuildShells(_ data: SphereWeaveView.SphereData) {
        for child in Array(shells.children) { child.removeFromParent() }
        dots.removeAll()
        addShell(data.documents, radius: 7, dot: 0.02,
                 color: Self.documentColor, labelAll: false)
        addShell(data.people, radius: 11, dot: 0.03,
                 color: Self.personColor, labelAll: true)
        addShell(data.places, radius: 15, dot: 0.03,
                 color: Self.placeColor, labelAll: true)
    }

    private func addShell(_ items: [SphereWeaveView.SphereData.Item],
                          radius: Float, dot: Float, color: UIColor,
                          labelAll: Bool) {
        let positions = WeaveLattice.points(count: items.count,
                                            radius: radius * Self.metersPerUnit)
        // One mesh, material, and collision shape for the whole shell:
        // per-dot copies of these were the volume's first memory bomb.
        let mesh = MeshResource.generateSphere(radius: dot)
        let material = SimpleMaterial(color: color, isMetallic: false)
        let shape = ShapeResource.generateSphere(radius: max(dot * 2.5, 0.05))
        var labelsLeft = Self.labelCap
        for (item, position) in zip(items, positions) {
            let entity = ModelEntity(mesh: mesh, materials: [material])
            entity.name = item.id
            entity.position = position
            // A finger needs more to aim at than the dot itself. Tap
            // targeting only — no hover effect; hover surfaces live in
            // the compositor and hundreds of them helped kill it.
            entity.components.set(InputTargetComponent())
            entity.components.set(CollisionComponent(shapes: [shape]))
            if labelAll, labelsLeft > 0 {
                labelsLeft -= 1
                entity.addChild(Self.labelEntity(item.label, color: color,
                                                 textHeight: 0.045))
            }
            shells.addChild(entity)
            dots[item.id] = entity
        }
    }

    /// The center element and its threads, redrawn per centering.
    /// Connected documents put their names on (capped); the rest of
    /// the documents stay quiet dots.
    private func rebuildThreads(_ data: SphereWeaveView.SphereData) {
        for child in Array(threads.children) { child.removeFromParent() }
        // Document labels show only for what the center touches.
        var labelsLeft = Self.labelCap
        for item in data.documents {
            guard let entity = dots[item.id] else { continue }
            for child in Array(entity.children) { child.removeFromParent() }
            if data.connected.contains(item.id), labelsLeft > 0 {
                labelsLeft -= 1
                entity.addChild(Self.labelEntity(item.label,
                                                 color: Self.documentColor,
                                                 textHeight: 0.035))
            }
        }
        guard !data.centerID.isEmpty else { return }
        // The center wears no dot — just its name, framed: a plaque
        // at the heart of the weave.
        threads.addChild(Self.centerPlaque(data.centerLabel,
                                           id: data.centerID))
        // Threads from the center to everything it touches — capped;
        // a word the whole library contains would otherwise draw a
        // thread per document.
        for id in data.connected.sorted().prefix(250) {
            guard let target = dots[id] else { continue }
            threads.addChild(Self.thread(to: target.position))
        }
    }

    /// The centered element as words in a frame — no sphere, just the
    /// name with four thin beams around it, turning to face the viewer.
    private static func centerPlaque(_ label: String, id: String) -> Entity {
        let mesh = MeshResource.generateText(
            String(label.prefix(40)),
            extrusionDepth: 0.0005,
            font: .systemFont(ofSize: 0.06, weight: .semibold),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byTruncatingTail)
        let material = UnlitMaterial(color: UIColor.black)
        let text = ModelEntity(mesh: mesh, materials: [material])
        let bounds = mesh.bounds
        // The words centered on the plaque's own origin.
        text.position = [-bounds.center.x, -bounds.center.y, 0]

        let plaque = Entity()
        plaque.name = id
        plaque.addChild(text)

        // The frame around the words.
        let pad: Float = 0.035
        let width = bounds.extents.x + pad * 2
        let height = bounds.extents.y + pad * 2
        let bar: Float = 0.005
        let horizontal = MeshResource.generateBox(width: width + bar,
                                                  height: bar, depth: 0.002)
        let vertical = MeshResource.generateBox(width: bar,
                                                height: height + bar, depth: 0.002)
        for y in [height / 2, -height / 2] {
            let edge = ModelEntity(mesh: horizontal, materials: [material])
            edge.position = [0, y, 0]
            plaque.addChild(edge)
        }
        for x in [width / 2, -width / 2] {
            let edge = ModelEntity(mesh: vertical, materials: [material])
            edge.position = [x, 0, 0]
            plaque.addChild(edge)
        }
        plaque.components.set(BillboardComponent())
        return plaque
    }

    /// A name beside a dot, as a flat text mesh that turns to face the
    /// viewer — no SwiftUI surface, just geometry the app itself owns.
    private static func labelEntity(_ text: String, color: UIColor,
                                    textHeight: Float) -> Entity {
        let mesh = MeshResource.generateText(
            String(text.prefix(40)),
            extrusionDepth: 0.0005,
            font: .systemFont(ofSize: CGFloat(textHeight), weight: .medium),
            containerFrame: .zero,
            alignment: .left,
            lineBreakMode: .byTruncatingTail)
        let entity = ModelEntity(mesh: mesh,
                                 materials: [UnlitMaterial(color: color)])
        entity.position = [0.04, 0.025, 0]
        entity.components.set(BillboardComponent())
        return entity
    }

    /// One unit-height beam and one material, shared by every thread;
    /// each thread is the beam scaled to its length. The fade lives in
    /// the material, not an OpacityComponent — opacity groups are
    /// compositor work, and there can be hundreds of threads.
    private static let threadMesh = MeshResource.generateBox(
        width: 0.002, height: 1, depth: 0.002)
    private static let threadMaterial: UnlitMaterial = {
        var material = UnlitMaterial(color: .black)
        material.blending = .transparent(opacity: 0.35)
        return material
    }()

    /// A thread from the center to a point: a hair-thin beam, faded.
    private static func thread(to end: SIMD3<Float>) -> Entity {
        let length = simd_length(end)
        guard length > 0.001 else { return Entity() }
        let entity = ModelEntity(mesh: threadMesh,
                                 materials: [threadMaterial])
        entity.scale = [1, length, 1]
        entity.position = end / 2
        entity.orientation = simd_quatf(from: [0, 1, 0], to: end / length)
        return entity
    }
}
#endif
