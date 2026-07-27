import SwiftUI
import FoundationModels

/// The column beside the reader: the read state on top, Action (the
/// note's standing — To Do, In Progress, Done), File (the folders
/// shared with Origami Text, with Archive and a new folder under a
/// rule), the AI analyses written into the note's Visual-Meta — click
/// to run, un-click to remove — and the note's place at the foot
/// (click to edit).
struct NoteOptionsColumn: View {
    @Environment(AppState.self) private var state
    let doc: LiquidDoc
    /// Settings ▸ Appearance can lay the controls under the note
    /// instead: the same sections, standing side by side in a bar.
    var underNote = false

    @State private var running: Set<NoteAnalysis.Kind> = []
    @State private var errorText: String?
    @State private var editingLocation = false
    @State private var locationText = ""

    private var modelAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    var body: some View {
        if underNote { bottomBar } else { sideColumn }
    }

    private var sideColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                actionSection
                fileSection
                analysisSection
                flowSection
                if doc.body != nil {
                    locationRow
                }
                if let errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 180)
        // The sidebar's grey, mirrored on the window's other edge.
        .greyColumnAppearance()
    }

    /// The same controls under the note: each section keeps its
    /// column's width and they stand shoulder to shoulder, the bar
    /// scrolling when the window runs out of room.
    private var bottomBar: some View {
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 28) {
                actionSection
                    .frame(width: 170)
                fileSection
                    .frame(width: 170)
                VStack(alignment: .leading, spacing: 20) {
                    analysisSection
                    flowSection
                    if doc.body != nil {
                        locationRow
                    }
                    if let errorText {
                        Text(errorText)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(width: 190, alignment: .leading)
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 235)
        .greyColumnAppearance()
    }

    // MARK: Action

    /// The note's standing — written into the file itself, so every
    /// device agrees. Clicking the current standing clears it back to
    /// nothing; setting one saves the note out of the drafts.
    private var actionSection: some View {
        section("Action") {
            ForEach(LiquidDoc.Action.allCases, id: \.self) { action in
                actionButton(action)
            }
        }
    }

    private func actionButton(_ action: LiquidDoc.Action) -> some View {
        Button {
            state.setAction(doc.actionValue == action ? nil : action, for: doc)
        } label: {
            HStack {
                Text(action.displayName)
                if doc.actionValue == action {
                    Spacer(minLength: 4)
                    Image(systemName: "checkmark")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(GreyColumnButtonStyle())
    }

    // MARK: File

    private var fileSection: some View {
        section("File") {
            // A letter's own file comes first: done means filed under
            // Letters, out of Draft Letters.
            if doc.documentType == LiquidDoc.DocumentType.letter.rawValue {
                filingButton("Letters", label: "Letter")
            }
            ForEach(SidebarCatalog.standardFiles, id: \.folder) { file in
                filingButton(file.folder, label: file.label)
            }
            ForEach(fileFolders, id: \.self) { folder in
                filingButton(folder)
            }
            Divider()
            HStack {
                Button("Archive") {
                    state.fileDocument(doc, under: AppState.archivedFolderName)
                    state.setDraft(false, for: doc)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .help("File the note away: it leaves the library's lists")
                Spacer()
                #if os(macOS)
                Button {
                    state.fileInNewFolder(doc)
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("A new folder, with this note filed in it")
                #endif
            }
            Divider()
        }
    }

    /// The user's own folders: everything but the standard files and
    /// Archived, which have their own places in the column.
    private var fileFolders: [String] {
        state.filingFolders.filter { folder in
            folder.caseInsensitiveCompare(AppState.archivedFolderName) != .orderedSame
                && !SidebarCatalog.standardFiles.contains {
                    $0.folder.caseInsensitiveCompare(folder) == .orderedSame
                }
        }
    }

    private func filingButton(_ folder: String, label: String? = nil) -> some View {
        Button {
            if state.folder(for: doc) == folder {
                state.unfile(doc)
            } else {
                // Action folders may not be registered yet; a no-op
                // when the folder already exists.
                state.addFilingFolder(folder)
                state.fileDocument(doc, under: folder)
                // Filing is saving: the note leaves the drafts for the
                // timeline and the views.
                state.setDraft(false, for: doc)
            }
        } label: {
            HStack {
                Text(label ?? folder)
                if state.folder(for: doc) == folder {
                    Spacer(minLength: 4)
                    Image(systemName: "checkmark")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(GreyColumnButtonStyle())
    }

    // MARK: Analysis

    private var analysisSection: some View {
        section("Analysis") {
            HStack(spacing: 16) {
                ForEach(NoteAnalysis.Kind.allCases) { kind in
                    analysisToggle(kind)
                }
            }
            if let value = doc.sentimentValue {
                VStack(alignment: .leading, spacing: 2) {
                    Text(value.capitalized)
                        .font(.caption.weight(.semibold))
                    if let note = doc.sentimentNote {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !doc.topicKeywords.isEmpty {
                Text(doc.topicKeywords.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !modelAvailable {
                Text("Analysis uses the on-device model; enable Apple Intelligence to run it. Existing results still show, and un-clicking still removes them.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Results are written into the note itself as Visual-Meta; un-click to remove them.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Location

    /// Where the note was made — the format's free-form place name,
    /// shown quietly and clickable to correct or supply by hand.
    private var locationRow: some View {
        Button {
            locationText = AppLocations.display(doc.location) ?? ""
            editingLocation = true
        } label: {
            Text(AppLocations.display(doc.location) ?? "Add Location…")
                .font(.caption)
                .foregroundStyle(doc.location == nil
                                 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .help("Where the note was made — click to edit the displayed name")
        .popover(isPresented: $editingLocation, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Location")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Place name", text: $locationText)
                    .frame(width: 220)
                    .onSubmit(saveLocation)
                if let original = doc.location {
                    Text("Stored: \(original)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                HStack {
                    Spacer()
                    Button("Save") { saveLocation() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
        }
    }

    /// A note that has a place keeps it forever: changed text becomes
    /// the place's display alias (edited or removed in Settings ▸
    /// Locations, like Home and Work). Only a note without a place gets
    /// one written in.
    private func saveLocation() {
        editingLocation = false
        let trimmed = locationText.trimmingCharacters(in: .whitespaces)
        if let original = doc.location {
            if trimmed.isEmpty || trimmed.caseInsensitiveCompare(original) == .orderedSame {
                AppLocations.setAlias(nil, for: original)
            } else if trimmed != AppLocations.label(for: original) {
                AppLocations.setAlias(trimmed, for: original)
            }
        } else if !trimmed.isEmpty, doc.body != nil {
            write(replacingLocation(of: doc, with: trimmed))
        }
    }

    /// The note with its place changed and everything else carried over.
    private func replacingLocation(of doc: LiquidDoc, with location: String?) -> LiquidDoc {
        var updated = doc
        updated.location = location
        return updated
    }

    // MARK: Flow

    /// Flow, the reading aid from Digital Letters: dense prose broken
    /// open — the note's words rendered for reading, sentences on
    /// their own lines. The note itself is untouched; Unflow returns
    /// to writing.
    private var flowSection: some View {
        section("Reading") {
            Button {
                withAnimation(.snappy) { state.flowReading.toggle() }
            } label: {
                HStack {
                    Text(state.flowReading ? "Unflow" : "Flow")
                    if state.flowReading {
                        Spacer(minLength: 4)
                        Image(systemName: "checkmark")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(GreyColumnButtonStyle())
            .help("Break dense text open while reading: sentences get their own lines, clauses break after commas, parentheses stand apart — the note itself is untouched")
            Button {
                withAnimation(.snappy) { state.showsVisualMeta.toggle() }
            } label: {
                HStack {
                    Text("Visual-Meta")
                    if state.showsVisualMeta {
                        Spacer(minLength: 4)
                        Image(systemName: "checkmark")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(GreyColumnButtonStyle())
            .help("The note's Visual-Meta under its words — the appendix the file carries, or the block its own fields derive.")
        }
    }

    /// Quiet text, the location row's style — clicking runs the
    /// analysis and fills the name in; clicking again removes the
    /// written result.
    private func analysisToggle(_ kind: NoteAnalysis.Kind) -> some View {
        Button {
            if doc.hasAnalysis(kind) {
                write(NoteAnalysis.removing(kind, from: doc))
            } else {
                runAnalysis(kind)
            }
        } label: {
            HStack(spacing: 4) {
                Text(kind.displayName)
                    .font(.caption)
                    .foregroundStyle(doc.hasAnalysis(kind)
                                     ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                if running.contains(kind) {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(running.contains(kind)
                  || (!modelAvailable && !doc.hasAnalysis(kind)))
    }

    private func runAnalysis(_ kind: NoteAnalysis.Kind) {
        guard !running.contains(kind) else { return }
        running.insert(kind)
        errorText = nil
        Task {
            do {
                let updated = try await NoteAnalysis.run(kind, on: doc)
                write(updated)
            } catch {
                errorText = "The model could not respond: \(error.localizedDescription)"
            }
            running.remove(kind)
        }
    }

    /// The changed note, rewritten in place; the index rescan brings the
    /// new copy to everything showing it.
    private func write(_ updated: LiquidDoc) {
        do {
            try updated.jsonData().write(to: updated.fileURL, options: .atomic)
            state.index.rescan()
        } catch {
            errorText = "Could not save the note: \(error.localizedDescription)"
        }
    }

    // MARK: Layout

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }
}
