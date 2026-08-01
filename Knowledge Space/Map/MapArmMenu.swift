//
//  MapArmMenu.swift
//  Knowledge Space
//
//  The Map's forearm menus, after Interatlas: a hand-tracking session
//  anchors each wrist, and a row of glass chips rides up the forearm — the
//  left arm the way into the library (New Note, Thoughts, Journal,
//  Articles, the whole folder), the right arm Introduction & Settings.
//  A pinch on a chip runs its command.
//
//  Wrist anchoring needs a SpatialTrackingSession (and the
//  NSHandsTrackingUsageDescription in Info.plist); without the session the
//  anchors never track and nothing appears — the trap the earlier wrist
//  bangles fell into. Chips are laid out every frame because a hand moves.
//

#if os(visionOS)
import SwiftUI
import RealityKit

/// One chip on a forearm: a stable id (the entity name and tap key), the
/// word it shows, which arm it rides, and what a pinch does.
struct ArmChipSpec: Identifiable {
    let id: String
    let title: String
    let chirality: AnchoringComponent.Target.Chirality
    let action: () -> Void
}

/// Owns the hand-tracking session, the wrist/knuckle anchors, and the chip
/// entities. Held by the immersive view across RealityView updates; drives
/// its own per-frame layout from the view's scene-update subscription.
@MainActor
final class MapArmMenu {

    /// The chips, set once before the session starts.
    private(set) var specs: [ArmChipSpec] = []

    private var session: SpatialTrackingSession?
    private var started = false
    /// The scene-update subscription that drives `layout`; held so it
    /// lives as long as the menu does.
    var updateSubscription: EventSubscription?

    private struct Wrist {
        let wrist: AnchorEntity
        let knuckle: AnchorEntity
    }
    private var wrists: [WristSide: Wrist] = [:]
    /// The chip host entities (collision + input), keyed by spec id.
    private var hosts: [String: Entity] = [:]
    /// The SwiftUI chip attachments, keyed by spec id, seated on their host.
    private var chips: [String: Entity] = [:]

    /// A hashable stand-in for Chirality so it can key a dictionary.
    private enum WristSide: Hashable { case left, right
        var chirality: AnchoringComponent.Target.Chirality { self == .left ? .left : .right }
        init(_ c: AnchoringComponent.Target.Chirality) { self = (c == .left) ? .left : .right }
    }

    // MARK: Setup

    func configure(_ specs: [ArmChipSpec]) { self.specs = specs }

    /// Every chip attachment id the view must declare, so it can build one
    /// `Attachment` per chip and hand each entity back through `register`.
    var attachmentIDs: [String] { specs.map(\.id) }

    /// Starts hand tracking and builds the chip entities under `root` —
    /// a persistent entity the view keeps out of its own map sweep.
    func start(in root: Entity) {
        guard !started else { return }
        started = true
        Task { await startTracking(in: root) }
    }

    private func startTracking(in root: Entity) async {
        let session = SpatialTrackingSession()
        _ = await session.run(SpatialTrackingSession.Configuration(tracking: [.hand]))
        self.session = session

        for side in [WristSide.left, .right] {
            let wrist = AnchorEntity(.hand(side.chirality, location: .joint(for: .wrist)))
            let knuckle = AnchorEntity(.hand(side.chirality, location: .joint(for: .middleFingerKnuckle)))
            root.addChild(wrist)
            root.addChild(knuckle)
            wrists[side] = Wrist(wrist: wrist, knuckle: knuckle)
        }
        buildHosts()
    }

    /// One invisible, tappable host per chip, parented to its wrist anchor.
    private func buildHosts() {
        for spec in specs {
            guard let wrist = wrists[WristSide(spec.chirality)]?.wrist else { continue }
            let host = Entity()
            host.name = spec.id
            host.components.set(CollisionComponent(shapes: [.generateBox(size: SIMD3(0.11, 0.05, 0.04))]))
            host.components.set(InputTargetComponent())
            host.components.set(HoverEffectComponent())
            wrist.addChild(host)
            hosts[spec.id] = host
            seat(spec.id)
        }
    }

    /// Called by the view once each SwiftUI chip attachment entity exists.
    func register(_ entity: Entity?, id: String) {
        guard let entity else { return }
        entity.components.set(BillboardComponent())
        // Attachments render life-size; shrink to forearm scale.
        entity.scale = SIMD3(repeating: 0.3)
        chips[id] = entity
        seat(id)
    }

    private func seat(_ id: String) {
        guard let host = hosts[id], let chip = chips[id] else { return }
        chip.setParent(host)
        chip.position = .zero
    }

    // MARK: Per-frame layout

    /// Lays each arm's chips in a row up the forearm, lifted off the skin.
    /// Called every scene update — a hand is never still.
    func layout() {
        for side in [WristSide.left, .right] {
            guard let w = wrists[side], w.wrist.isAnchored, w.knuckle.isAnchored else { continue }
            // Up the forearm (toward the elbow) is the opposite of the
            // wrist→knuckle direction, in wrist-local space.
            let fingerWorld = w.knuckle.position(relativeTo: nil) - w.wrist.position(relativeTo: nil)
            let fingerLocal = w.wrist.convert(direction: fingerWorld, from: nil)
            let alongArm: SIMD3<Float> = fingerLocal.x >= 0 ? SIMD3(-1, 0, 0) : SIMD3(1, 0, 0)
            // World-up, made perpendicular to the arm, lifts the chips so
            // they float above the wrist rather than clipping the skin.
            var lift = w.wrist.convert(direction: SIMD3<Float>(0, 1, 0), from: nil)
            lift -= alongArm * simd_dot(lift, alongArm)
            let length = simd_length(lift)
            guard length > 1e-5 else { continue }
            lift /= length

            let sideSpecs = specs.filter { WristSide($0.chirality) == side }
            for (index, spec) in sideSpecs.enumerated() {
                guard let host = hosts[spec.id] else { continue }
                let up = 0.05 + Float(index) * 0.055   // spaced up the forearm
                host.position = alongArm * up + lift * 0.05
            }
        }
    }

    // MARK: Tap

    /// Runs the command of the chip a tapped entity belongs to. Walks up
    /// from the hit entity (the chip attachment or its host) to the named
    /// host. Returns whether it handled the tap.
    @discardableResult
    func handleTap(_ entity: Entity) -> Bool {
        var node: Entity? = entity
        while let current = node {
            if let spec = specs.first(where: { $0.id == current.name }) {
                spec.action()
                return true
            }
            node = current.parent
        }
        return false
    }
}

/// A forearm command: a word on a semi-transparent glass panel with a thin
/// frame, matching the Map's node cards. Non-interactive itself — the tap
/// is caught by the collision on the entity it rides.
struct ArmChip: View {
    let text: String
    var systemImage: String? = nil

    var body: some View {
        Label {
            Text(text)
        } icon: {
            if let systemImage { Image(systemName: systemImage) }
        }
        .labelStyle(.titleAndIcon)
        .font(.system(size: 22, weight: .semibold))
        .foregroundStyle(.white)
        .fixedSize()
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.white.opacity(0.35), lineWidth: 1)
        )
        .allowsHitTesting(false)
    }
}
#endif
