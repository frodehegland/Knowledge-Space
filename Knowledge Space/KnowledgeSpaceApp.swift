import SwiftUI

/// Knowledge Space: a reader for Origami Documents (`.origamitext`) —
/// the community-folder library presented as a browsable, linked space.
/// The document format and its data structures are shared with Origami
/// Text (see OrigamiText/ORIGAMI-DOCUMENT-FORMAT.md).
@main
struct KnowledgeSpaceApp: App {
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(state)
        }

        #if os(visionOS)
        // The volumetric space: every document a card, links as threads.
        WindowGroup(id: "knowledge-space") {
            KnowledgeSpaceView()
                .environment(state)
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 1.7, height: 1.1, depth: 0.7, in: .meters)
        #endif
    }
}
