//
//  PortraitSpatial.swift
//  Knowledge Space
//
//  Prototype: extend a flat portrait into 3D on visionOS. The macOS
//  pipeline (PersonPortraits) already turns a photo into a flat cartoon PNG
//  and publishes it to the community folder's Portraits/. Here that same
//  PNG is fed to RealityKit's ImagePresentationComponent.Spatial3DImage,
//  whose generate() produces a "spatial scene" — textured 3D geometry with
//  depth and motion parallax — the visionOS Photos "Convert to 3D" effect.
//
//  Notes / limits:
//  - Spatial scene = a depth relief with parallax, not a rotatable bust. A
//    true 360° model needs Object Capture (many photos), not one image.
//  - generate() runs on-device only; it THROWS in the visionOS Simulator,
//    so the 3D step must be tried on a real Vision Pro.
//  - The result is in-memory, so we ship the flat PNG (as today) and
//    generate the scene on demand here.
//

#if os(visionOS)
import SwiftUI
import RealityKit
import UniformTypeIdentifiers

/// Drives one portrait's 2D → 3D presentation on a single entity.
@MainActor
@Observable
final class PortraitSpatialModel {

    enum Phase: Equatable {
        case empty
        case ready2D
        case generating
        case spatial
        case failed(String)
    }

    private(set) var phase: Phase = .empty
    private(set) var imageURL: URL?

    /// The entity carrying the ImagePresentationComponent; persists across
    /// the RealityView's lifetime so mode changes show live.
    let presenter = Entity()
    private var spatialImage: ImagePresentationComponent.Spatial3DImage?

    /// Places the presenter in the window's volume. Called once from the
    /// RealityView's make closure.
    func setup(_ content: RealityViewContent) {
        presenter.position = SIMD3(0, 0, 0)
        content.add(presenter)
    }

    /// Loads a chosen image as a flat (mono) presentation to start from.
    func load(_ url: URL) {
        phase = .generating   // brief, while the texture loads
        Task { @MainActor in
            do {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                var component = try await ImagePresentationComponent(contentsOf: url)
                component.desiredViewingMode = .mono
                presenter.components.set(component)
                spatialImage = try await ImagePresentationComponent.Spatial3DImage(contentsOf: url)
                imageURL = url
                phase = .ready2D
            } catch {
                phase = .failed("Could not load the image: \(error.localizedDescription)")
            }
        }
    }

    /// The Photos-style "Convert to 3D": switch the component to the spatial
    /// mode and generate the scene. On a real device the component plays the
    /// generation animation and lands on the 3D relief.
    func convertTo3D() {
        guard let spatial = spatialImage else { return }
        phase = .generating
        // Post-generate flow: present the spatial image first (mono), flip
        // the desired mode, then generate — the component animates the
        // transition as generation finishes.
        var component = ImagePresentationComponent(spatial3DImage: spatial)
        component.desiredViewingMode = .spatial3D
        presenter.components.set(component)
        Task { @MainActor in
            do {
                try await spatial.generate()
                phase = .spatial
            } catch {
                // The Simulator always lands here; a real device generates.
                phase = .failed("Could not generate the 3D scene: \(error.localizedDescription)")
            }
        }
    }

    /// Flips a generated portrait back to flat, or to 3D again.
    func setMode(spatial: Bool) {
        guard var component = presenter.components[ImagePresentationComponent.self] else { return }
        component.desiredViewingMode = spatial ? .spatial3D : .mono
        presenter.components.set(component)
        phase = spatial ? .spatial : .ready2D
    }
}

/// The prototype window: choose a portrait (a Portraits/ PNG or any photo),
/// see it flat, and Convert to 3D.
struct PortraitSpatialView: View {
    @State private var model = PortraitSpatialModel()
    @State private var showingImporter = false

    var body: some View {
        VStack(spacing: 0) {
            RealityView { content in
                model.setup(content)
            }
            .frame(minWidth: 360, minHeight: 360)

            controls
                .padding(16)
        }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.image],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.load(url)
            }
        }
    }

    @ViewBuilder private var controls: some View {
        VStack(spacing: 10) {
            Text("Portrait → 3D (prototype)")
                .font(.headline)

            HStack(spacing: 12) {
                Button {
                    showingImporter = true
                } label: {
                    Label("Choose Portrait…", systemImage: "photo")
                }

                switch model.phase {
                case .empty:
                    Text("Pick a portrait PNG or photo to begin.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case .ready2D:
                    Button {
                        model.convertTo3D()
                    } label: {
                        Label("Convert to 3D", systemImage: "cube.transparent")
                    }
                    .buttonStyle(.borderedProminent)
                case .generating:
                    ProgressView().controlSize(.small)
                    Text("Working…").font(.footnote).foregroundStyle(.secondary)
                case .spatial:
                    Button {
                        model.setMode(spatial: false)
                    } label: {
                        Label("Show as 2D", systemImage: "rectangle")
                    }
                case .failed(let message):
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
            }

            Text("The 3D step generates a spatial scene on-device and works only on a real Vision Pro — it fails in the Simulator.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 520)
    }
}
#endif
