//
//  VisionArmMenu.swift
//  Knowledge Space iOS  (visionOS build)
//
//  A labelled pill button on each wrist opens a ring of category chips.
//  Left arm  "Show"   — tap a chip to toggle its category's visibility.
//  Right arm "Select" — tap a chip to select all docs of that type for group move.
//
//  Architecture
//  ───────────────────────────────────────────────────────────────────────
//  • init(chirality:)    — .left (default) or .right
//  • buildEager()        — synchronous, call from RealityView make closure.
//    Returns wrist + knuckle AnchorEntities; both must be direct content children.
//  • seatAttachments(_:) — idempotent, call from make and every update closure.
//    Seats the toggle button AND all chip attachments onto their host entities.
//  • attachToWrist()     — async, call from .task{}. Runs the hand-tracking session;
//    once authorised the toggle button becomes visible.
//  • layout()            — call every scene update via updateSubscription.
//  • toggleMenu()        — called by the view's TapGesture on the button host.
//  • collapseMenu()      — collapses without toggling if already open.
//

#if os(visionOS)
import SwiftUI
import RealityKit

// MARK: - Filter specs

struct VisionFilterSpec: Identifiable {
    let id: String
    let label: String
    let icon: String
    let types: Set<String>
    let color: Color
}

// MARK: - Arm menu

@MainActor
final class VisionArmMenu {

    // MARK: Chirality

    enum Chirality { case left, right }

    let chirality: Chirality

    init(chirality: Chirality = .left) {
        self.chirality = chirality
    }

    private var idPrefix: String { chirality == .left ? "" : "r:" }
    private var toggleEntityName: String { chirality == .left ? "arm:toggle:l" : "arm:toggle:r" }
    var buttonLabel: String { chirality == .left ? "Show" : "Select" }

    // MARK: Filter catalogue

    static let filters: [VisionFilterSpec] = [
        VisionFilterSpec(id: "arm:note",       label: "Notes",       icon: "note.text",      types: ["note"],                color: .yellow),
        VisionFilterSpec(id: "arm:thought",    label: "Thoughts",    icon: "lightbulb",      types: ["thought"],             color: .orange),
        VisionFilterSpec(id: "arm:journal",    label: "Journal",     icon: "book.closed",    types: ["journal"],             color: .green),
        VisionFilterSpec(id: "arm:letter",     label: "Letters",     icon: "envelope",       types: ["letter"],              color: .blue),
        VisionFilterSpec(id: "arm:book",       label: "Books",       icon: "books.vertical", types: ["book"],                color: .purple),
        VisionFilterSpec(id: "arm:source",     label: "Sources",     icon: "doc.richtext",   types: ["source"],              color: .indigo),
        VisionFilterSpec(id: "arm:article",    label: "Articles",    icon: "newspaper",      types: ["article", "external"], color: Color(white: 0.7)),
        VisionFilterSpec(id: "arm:transcript", label: "Transcripts", icon: "quote.bubble",   types: ["transcript"],          color: .teal),
        VisionFilterSpec(id: "arm:annotation", label: "Annotations", icon: "highlighter",    types: ["annotation", "quote"], color: .pink),
    ]

    // MARK: State

    private(set) var isMenuExpanded = false
    private(set) var chipHosts: [String: Entity] = [:]
    /// Invisible interaction target for the pill button attachment.
    private var toggleHost: Entity?
    /// Settings button — right arm only.
    private var settingsHost: Entity?
    private static let settingsEntityName = "arm:settings:r"
    private var wristAnchor: AnchorEntity?
    private var knuckleAnchor: AnchorEntity?
    var updateSubscription: EventSubscription?

    /// Called after the shared SpatialTrackingSession has started.
    func enableButton() {
        toggleHost?.isEnabled = true
        settingsHost?.isEnabled = true
    }

    // MARK: Eager build — synchronous, call from make closure

    func buildEager() -> [AnchorEntity] {
        let wrist: AnchorEntity
        let knuckle: AnchorEntity
        if chirality == .left {
            wrist   = AnchorEntity(.hand(.left, location: .joint(for: .wrist)))
            knuckle = AnchorEntity(.hand(.left, location: .joint(for: .middleFingerKnuckle)))
        } else {
            wrist   = AnchorEntity(.hand(.right, location: .joint(for: .wrist)))
            knuckle = AnchorEntity(.hand(.right, location: .joint(for: .middleFingerKnuckle)))
        }
        wrist.name   = "arm:wristAnchor:\(idPrefix)"
        knuckle.name = "arm:knuckleAnchor:\(idPrefix)"
        wristAnchor   = wrist
        knuckleAnchor = knuckle

        // Toggle button host — invisible box that receives the pinch.
        // The SwiftUI pill button is seated on it by seatAttachments().
        let toggle = Entity()
        toggle.name = toggleEntityName
        toggle.components.set(CollisionComponent(
            shapes: [.generateBox(size: SIMD3(0.10, 0.04, 0.02))],
            mode: .trigger,
            filter: .sensor
        ))
        toggle.components.set(InputTargetComponent(allowedInputTypes: .indirect))
        toggle.components.set(HoverEffectComponent())
        toggle.isEnabled = false
        wrist.addChild(toggle)
        toggleHost = toggle

        // Chip hosts — disabled until the menu is opened.
        for spec in Self.filters {
            let host = Entity()
            host.name = idPrefix + spec.id
            host.components.set(CollisionComponent(
                shapes: [.generateBox(size: SIMD3(0.11, 0.05, 0.04))],
                mode: .trigger,
                filter: .sensor
            ))
            host.components.set(InputTargetComponent(allowedInputTypes: .indirect))
            host.isEnabled = false
            wrist.addChild(host)
            chipHosts[spec.id] = host
        }

        // Settings button — right arm only, positioned along the forearm by layout().
        if chirality == .right {
            let settings = Entity()
            settings.name = Self.settingsEntityName
            settings.components.set(CollisionComponent(
                shapes: [.generateBox(size: SIMD3(0.10, 0.04, 0.02))],
                mode: .trigger,
                filter: .sensor
            ))
            settings.components.set(InputTargetComponent(allowedInputTypes: .indirect))
            settings.components.set(HoverEffectComponent())
            settings.isEnabled = false
            wrist.addChild(settings)
            settingsHost = settings
        }

        return [wrist, knuckle]
    }

    /// Idempotent — seats the pill button AND all chip SwiftUI attachments.
    func seatAttachments(_ attachments: RealityViewAttachments) {
        // Toggle button
        if let host = toggleHost {
            let childName = "aatn:" + toggleEntityName
            if host.findEntity(named: childName) == nil,
               let entity = attachments.entity(for: toggleEntityName) {
                entity.name = childName
                entity.components.set(BillboardComponent())
                entity.scale = SIMD3(repeating: 0.35)
                host.addChild(entity)
            }
        }

        // Settings button (right arm only)
        if let host = settingsHost {
            let childName = "aatn:" + Self.settingsEntityName
            if host.findEntity(named: childName) == nil,
               let entity = attachments.entity(for: Self.settingsEntityName) {
                entity.name = childName
                entity.components.set(BillboardComponent())
                entity.scale = SIMD3(repeating: 0.35)
                host.addChild(entity)
            }
        }

        // Category chips
        for spec in Self.filters {
            let attachID = idPrefix + spec.id
            guard let host = chipHosts[spec.id] else { continue }
            let childName = "aatn:" + attachID
            guard host.findEntity(named: childName) == nil,
                  let entity = attachments.entity(for: attachID) else { continue }
            entity.name = childName
            entity.components.set(BillboardComponent())
            entity.scale = SIMD3(repeating: 0.3)
            host.addChild(entity)
        }
    }

    // MARK: Toggle

    func toggleMenu() {
        isMenuExpanded.toggle()
        for host in chipHosts.values { host.isEnabled = isMenuExpanded }
        // Button visual is handled by SwiftUI state in the parent view.
    }

    func collapseMenu() {
        guard isMenuExpanded else { return }
        toggleMenu()
    }

    // MARK: Per-frame layout

    func layout() {
        guard let wrist   = wristAnchor,   wrist.isAnchored,
              let knuckle = knuckleAnchor, knuckle.isAnchored else { return }

        let fingerWorld = knuckle.position(relativeTo: nil) - wrist.position(relativeTo: nil)
        let fingerLen   = simd_length(fingerWorld)
        guard fingerLen > 0.001 else { return }
        let armLocal = simd_normalize(wrist.convert(direction: fingerWorld / fingerLen, from: nil))

        let worldUpLocal = wrist.convert(direction: SIMD3<Float>(0, 1, 0), from: nil)
        var right = simd_cross(armLocal, worldUpLocal)
        let rightLen = simd_length(right)
        guard rightLen > 1e-5 else { return }
        right /= rightLen
        // `lift` points away from the skin (dorsal direction, toward viewer).
        let lift = simd_normalize(simd_cross(right, armLocal))

        // Toggle button floats 7 cm above the wrist in the dorsal direction,
        // mirroring MapArmMenu's chip positioning so it is above the skin, not
        // buried inside the wrist joint at (0,0,0).
        let togglePos = lift * 0.07
        toggleHost?.position = togglePos

        // Settings button: 7 cm further toward the elbow (-armLocal direction)
        // from the toggle, at the same dorsal lift — so it reads as "below" the
        // Select button when the arm hangs naturally.
        settingsHost?.position = togglePos - armLocal * 0.07

        // Chip ring is centred at the toggle position.
        let chipRadius: Float = 0.09
        let count = Self.filters.count
        for (index, spec) in Self.filters.enumerated() {
            guard let host = chipHosts[spec.id] else { continue }
            let angle = 2 * Float.pi * Float(index) / Float(count) - Float.pi / 2
            host.position = togglePos + right * chipRadius * cos(angle) + lift * chipRadius * sin(angle)
        }
    }

    // MARK: Tap routing

    func isToggle(_ entity: Entity) -> Bool {
        var node: Entity? = entity
        while let current = node {
            if current.name == toggleEntityName { return true }
            node = current.parent
        }
        return false
    }

    func isSettings(_ entity: Entity) -> Bool {
        var node: Entity? = entity
        while let current = node {
            if current.name == Self.settingsEntityName { return true }
            node = current.parent
        }
        return false
    }

    func specID(for entity: Entity) -> String? {
        var node: Entity? = entity
        while let current = node {
            let name = current.name
            let candidate = (!idPrefix.isEmpty && name.hasPrefix(idPrefix))
                ? String(name.dropFirst(idPrefix.count))
                : name
            if Self.filters.contains(where: { $0.id == candidate }) { return candidate }
            node = current.parent
        }
        return nil
    }
}

// MARK: - Wrist button view

struct VisionArmToggleButton: View {
    let label: String
    let isExpanded: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Capsule().fill(.regularMaterial))
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(isExpanded ? 0.7 : 0.35), lineWidth: 1.5)
            )
            .allowsHitTesting(false)
    }
}

// MARK: - Settings button view

struct VisionArmSettingsButton: View {
    var body: some View {
        Label("Settings", systemImage: "gearshape")
            .labelStyle(.titleAndIcon)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1.5))
            .allowsHitTesting(false)
    }
}

// MARK: - Category chip view

struct VisionFilterChip: View {
    let spec: VisionFilterSpec
    let isHidden: Bool

    var body: some View {
        Label(spec.label, systemImage: spec.icon)
            .labelStyle(.titleAndIcon)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(isHidden ? Color.white.opacity(0.4) : spec.color)
            .fixedSize()
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        isHidden
                            ? AnyShapeStyle(Color.white.opacity(0.15))
                            : AnyShapeStyle(spec.color.opacity(0.5)),
                        lineWidth: 1.5
                    )
            )
            .opacity(isHidden ? 0.4 : 1.0)
            .allowsHitTesting(false)
    }
}

#endif
