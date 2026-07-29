import SwiftUI

/// The reading view for one Origami Document: serif typography, heading
/// scale, live address links, the Visual-Meta appendix de-emphasized, and
/// backlinks gathered from the library index. Arrival by fragment link
/// scrolls to the paragraph and flashes it.
struct DocumentReaderView: View {
    @Environment(AppState.self) private var state
    let doc: LiquidDoc
    /// The text measure — nil reflows with the pane, a margin either
    /// side — and whether the page stands at the pane's left (the
    /// window's reading column) or its center (full screen).
    var measure: CGFloat? = nil
    var centersContent: Bool = false
    /// Inline: the document expanded in the list itself (Settings ▸
    /// Appearance, "In the list"). The list scrolls, so no scroll
    /// view — or fragment scrolling — of its own.
    var inline: Bool = false

    var body: some View {
        if inline {
            readerColumn
                .padding(.vertical, 8)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    readerColumn
                        .padding(24)
                }
                .onAppear { scrollToPendingFragment(proxy) }
                .onChange(of: state.pendingFragment) { scrollToPendingFragment(proxy) }
            }
        }
    }

    private var readerColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            // The study's terms — keywords, concepts, and names tagged
            // person — as live chips, the same interactions the source
            // pages offer: digests and any other document carrying a
            // concept pool.
            if !doc.concepts.isEmpty {
                termChips
            }
            if let body = doc.body {
                let appendixIDs = doc.visualMetaParagraphIDs
                    .union(doc.analysisParagraphIDs)
                ForEach(body.filter {
                    state.showsVisualMeta || !appendixIDs.contains($0.id)
                }) { paragraph in
                    // A "Photo: <name>" line names an image beside the
                    // note in the folder (a scan's capture) — shown as
                    // the picture itself, clickable to open full size.
                    if let name = Self.photoFileName(in: paragraph.text) {
                        photoView(name)
                            .id(paragraph.id)
                    } else {
                        ParagraphView(paragraph: paragraph,
                                      isAppendix: appendixIDs.contains(paragraph.id),
                                      isHighlighted: paragraph.id == state.pendingFragment,
                                      flowed: state.flowReading,
                                      transcript: paragraph.speaker == nil ? nil : doc)
                            .id(paragraph.id)
                    }
                }
            } else if let wraps = doc.wraps {
                sidecarView(wraps)
            }
            // Visual-Meta is every document's visible companion: a file
            // that carries its appendix shows it above (half size, after
            // its rule); one that does not yet shows the block derived
            // from its own fields, so the metadata always stands on the
            // page with the words. The button at the foot folds it away
            // and back, per reading.
            if state.showsVisualMeta, doc.visualMetaParagraphIDs.isEmpty {
                derivedVisualMeta
            }
            metadataToggle
            backlinksSection
        }
        // The reading measure: the column's width in the
        // window, or a comfortable fixed line centered on the
        // full-screen page.
        .frame(maxWidth: measure ?? .infinity, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: centersContent ? .center : .leading)
    }

    private func scrollToPendingFragment(_ proxy: ScrollViewProxy) {
        guard let fragment = state.pendingFragment else { return }
        withAnimation { proxy.scrollTo(fragment, anchor: .center) }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if state.pendingFragment == fragment {
                state.pendingFragment = nil
            }
        }
    }

    // MARK: Header

    /// A note's title is only its first words, and its when and where
    /// live in the list — so a note has no header at all: one empty
    /// line, then the words.
    private var isNote: Bool {
        doc.documentType == LiquidDoc.DocumentType.note.rawValue
    }

    @ViewBuilder private var header: some View {
        if isNote {
            Color.clear.frame(height: 17)
            warnings
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(doc.title)
                    .font(.system(size: 34, weight: .bold, design: .serif))
                HStack(spacing: 6) {
                    Text(doc.displayAuthor)
                        .fontWeight(.medium)
                    Text("·")
                    Text(doc.listedDateText)
                    if let location = doc.location {
                        Text("·")
                        // Home and Work read as their labels; the note
                        // itself keeps the full place name.
                        Text(AppLocations.display(location) ?? location)
                    }
                }
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                if !doc.attention.isEmpty {
                    Text("For the attention of \(doc.attention.joined(separator: " and "))")
                        .font(.system(size: 13))
                        .italic()
                        .foregroundStyle(.secondary)
                }
                // A digest is a pointer as much as a page: the way to
                // its original stands right under the title.
                if doc.isDigest {
                    Button {
                        state.openDigestOriginal(doc)
                    } label: {
                        Label("Open Original", systemImage: "arrow.up.forward.app")
                    }
                    .help("Opens the file this digest distills, in whatever app owns it")
                }
                #if os(macOS)
                // An adopted email keeps its way back into Mail.
                if let mail = Self.mailPointerURL(of: doc) {
                    Button {
                        NSWorkspace.shared.open(mail)
                    } label: {
                        Label("Open in Mail", systemImage: "envelope.open")
                    }
                    .help("Opens the original message in Mail")
                }
                #endif
                warnings
                Divider()
            }
        }
    }

    /// The banners that must show whatever the header style: retraction,
    /// revision, and format warnings.
    @ViewBuilder private var warnings: some View {
        if state.index.retractedIDs.contains(doc.id) {
            banner("This document was retracted by its author.",
                   systemImage: "xmark.octagon", tint: .red)
        }
        if state.index.supersededIDs.contains(doc.id) {
            HStack {
                banner("A newer revision of this document exists.",
                       systemImage: "clock.arrow.circlepath", tint: .orange)
                Button("Open Latest") {
                    state.open(id: state.index.latestRevision(of: doc.id))
                }
            }
        }
        if doc.hasUnfamiliarFormatVersion {
            banner("Written in an unfamiliar format version (\(doc.format)); shown with best effort.",
                   systemImage: "questionmark.circle", tint: .orange)
        }
    }

    private func banner(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(tint)
            .padding(8)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Photo

    /// The image filename a "Photo: <name>" line names — a plain name
    /// in the same folder, not a path.
    static func photoFileName(in text: String) -> String? {
        guard text.hasPrefix("Photo: ") else { return nil }
        let name = String(text.dropFirst("Photo: ".count))
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/") else { return nil }
        return name
    }

    /// The scan's photograph, shown in the note and clickable to open
    /// full size in the system's viewer.
    @ViewBuilder private func photoView(_ name: String) -> some View {
        let url = state.index.folderURL?.appendingPathComponent(name)
        #if os(macOS)
        if let url, let image = NSImage(contentsOf: url) {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 320, maxHeight: 320, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("Open the photo full size")
        } else {
            Label(name, systemImage: "photo")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        #else
        Label(name, systemImage: "photo")
            .font(.callout)
            .foregroundStyle(.secondary)
        #endif
    }

    // MARK: Sidecar

    /// A sidecar wraps an external file, giving it an address and links.
    private func sidecarView(_ wraps: LiquidDoc.Wrapped) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(wraps.file, systemImage: "paperclip")
                .font(.title3)
            if let mediaType = wraps.mediaType {
                Text(mediaType)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("This document wraps the file above, which lives beside it in the library folder.")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    /// Metadata / Hide Metadata, quiet at the document's foot.
    private var metadataToggle: some View {
        Button(state.showsVisualMeta ? "Hide Metadata" : "Metadata") {
            withAnimation(.snappy) { state.showsVisualMeta.toggle() }
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.tertiary)
        .help("The document's Visual-Meta, shown on the page — the appendix its file carries, or the block its own fields derive")
    }

    /// The derived Visual-Meta block, at the appendix's half size.
    private var derivedVisualMeta: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
                .padding(.top, 12)
            Text(VisualMeta.displayBlock(for: doc))
                .font(.system(size: 9, design: .serif))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    /// The message:// link an adopted email carries in its pointer line.
    static func mailPointerURL(of doc: LiquidDoc) -> URL? {
        guard let line = (doc.body ?? []).last(where: { $0.text.hasPrefix("Email: message://") })
        else { return nil }
        return URL(string: String(line.text.dropFirst("Email: ".count))
            .trimmingCharacters(in: .whitespaces))
    }

    // MARK: Term chips

    /// A term on its way into the contacts, via its chip's menu.
    @State private var newPerson: Person?

    private var termChips: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)],
                  alignment: .leading, spacing: 6) {
            ForEach(doc.concepts) { concept in
                termChip(concept)
            }
        }
        #if os(macOS)
        .sheet(item: $newPerson) { person in
            PersonFormView(person: person, heading: "New Person") { updated in
                state.people.upsert(updated)
                state.publishPortraits()
                state.index.rescan()
            }
        }
        #endif
    }

    /// One term as a live button — SourcesView's chip, word for word:
    /// any view narrowed to the term; a name also stands in People or
    /// Authors, or begins a contact record.
    private func termChip(_ concept: LiquidDoc.Concept) -> some View {
        let isName = concept.tag == "person"
        return Menu {
            Menu("Show in") {
                ForEach(LibraryViewRegistry.modules) { module in
                    Button(module.name) {
                        state.showTerm(concept.name, inView: module.id, from: doc.id)
                    }
                }
            }
            if isName {
                Divider()
                Button("Show in People") { state.showPerson(concept.name) }
                Button("Show in Authors") { state.showCitedAuthor(concept.name) }
                #if os(macOS)
                if state.people.person(named: concept.name) == nil {
                    Button("Add to Contacts…") {
                        newPerson = Person(displayName: concept.name)
                    }
                }
                #endif
            }
        } label: {
            HStack(spacing: 4) {
                if isName {
                    Image(systemName: "person")
                }
                Text(concept.name)
                    .lineLimit(1)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .help(isName
              ? "A name the document mentions — open it in any view, see the person, or start a contact"
              : "Open any view narrowed to “\(concept.name)”")
    }

    // MARK: Backlinks

    private var backlinks: [BacklinkRef] {
        state.index.backlinks[doc.id] ?? []
    }

    @ViewBuilder
    private var backlinksSection: some View {
        if !backlinks.isEmpty {
            Divider()
                .padding(.top, 12)
            Text("Backlinks")
                .font(.system(size: 19, design: .serif))
            ForEach(backlinks, id: \.self) { ref in
                if let entry = state.index.byID[ref.fromID] {
                    Button {
                        state.open(id: ref.fromID)
                    } label: {
                        HStack(spacing: 6) {
                            Text(entry.doc.title)
                                .underline()
                            if let label = DocumentRelation.from(rel: ref.rel)?.bylineLabel {
                                Text(label.lowercased())
                                    .foregroundStyle(.secondary)
                            }
                            Text("— \(entry.doc.displayAuthor)")
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// One paragraph, rendered per the body-text conventions: heading levels
/// (structured or `#`-prefixed), dash-only paragraphs as rules, inline
/// markdown, and addresses as live links. Appendix paragraphs render at
/// half size — metadata, not content.
struct ParagraphView: View {
    @Environment(AppState.self) private var state

    let paragraph: LiquidDoc.Paragraph
    var isAppendix = false
    var isHighlighted = false
    /// Flow: break dense prose open for reading (sentences, clauses,
    /// parentheses). Display only; headings and the appendix are left
    /// alone.
    var flowed = false
    /// The transcript this paragraph speaks in, when it does: with it,
    /// the speaker's name becomes a menu — see the person in any view,
    /// or copy their words into notes that cite their way back.
    var transcript: LiquidDoc? = nil
    /// Whether to draw the speaker's name in the left column. False for a
    /// paragraph continuing the turn above it, so a long turn shows its
    /// speaker once rather than before every paragraph.
    var showsSpeakerLabel = true

    private var isRule: Bool {
        let text = paragraph.displayText
        return text.count >= 3 && text.allSatisfy { $0 == "-" }
    }

    private var shownText: AttributedString {
        if flowed, !isAppendix, paragraph.effectiveHeading == nil {
            return FlowBreaker.flowed(paragraph.renderedText)
        }
        return paragraph.renderedText
    }

    var body: some View {
        if isRule {
            Divider()
        } else if let speaker = paragraph.speaker {
            // A transcript line, set like a script: the name in its own
            // column at the left, the words beside it. Only the words
            // are selectable — text selection on the whole row swallows
            // the clicks the name's menu needs.
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Group {
                    if let transcript {
                        speakerMenu(speaker, in: transcript)
                    } else {
                        speakerLabel(speaker)
                    }
                }
                .frame(width: 130, alignment: .trailing)
                Text(shownText)
                    .font(font)
                    .lineSpacing(6 * scale)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(4)
            .background(isHighlighted ? Color.yellow.opacity(0.35) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 4))
            .animation(.easeOut(duration: 0.6), value: isHighlighted)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(shownText)
                    .font(font)
                    .lineSpacing((paragraph.effectiveHeading == nil ? 6 : 3) * scale)
            }
            .padding(4)
            .background(isHighlighted ? Color.yellow.opacity(0.35) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 4))
            .animation(.easeOut(duration: 0.6), value: isHighlighted)
            .textSelection(.enabled)
        }
    }

    /// The name as the column shows it, menu or not. A model is tinted
    /// apart from a person, so a reader tells the two sides of an AI
    /// conversation at a glance.
    private func speakerLabel(_ name: String, isAgent: Bool = false) -> some View {
        Text(name)
            .font(.system(size: 13 * scale, weight: .semibold))
            .foregroundStyle(isAgent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .multilineTextAlignment(.trailing)
    }

    /// The speaker's name and, for a generated turn, its standing beneath —
    /// so a model's words wear "unverified" until a reader says otherwise.
    private func speakerColumn(_ speaker: String, in transcript: LiquidDoc) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            speakerMenu(speaker, in: transcript)
            if paragraph.provenance == "generated" {
                Text(paragraph.verification == "verified" ? "verified" : "unverified")
                    .font(.system(size: 10 * scale))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// The speaker's name as the system's name-menu. For a person: the
    /// person in any view, and their words copied into a citing note. For
    /// a model (an agent of this document), its recorded identity stands
    /// in place of the People doors — a model is never a contact — and the
    /// same copy-to-note actions carry the provenance across.
    private func speakerMenu(_ speaker: String, in transcript: LiquidDoc) -> some View {
        let agent = transcript.agent(named: speaker)
        return Menu {
            if let agent {
                Section("Model") {
                    Text(agent.modelRaw ?? agent.name)
                    if let vendor = agent.vendor { Text(vendor) }
                    if let confidence = agent.modelConfidence, confidence != "readFromUI" {
                        Text("model identity: \(confidence)")
                    }
                }
            } else {
                Menu("Show in") {
                    ForEach(LibraryViewRegistry.modules) { module in
                        Button(module.name) {
                            state.showTerm(speaker, inView: module.id, from: transcript.id)
                        }
                    }
                }
                Button("Show in People") { state.showPerson(speaker) }
                Button("Show in Authors") { state.showCitedAuthor(speaker) }
            }
            Divider()
            Button("Copy to Note") {
                state.liftStatement(paragraph, from: transcript)
            }
            Button("Copy All of \(speaker) to Note") {
                state.liftAllStatements(of: speaker, from: transcript)
            }
        } label: {
            speakerLabel(speaker, isAgent: agent != nil)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .help(agent == nil
            ? "\(speaker) — see the person in any view, or copy what they said here (or everywhere in this transcript) into a note linked back to its source"
            : "\(speaker) — a model; copy what it said here (or everywhere in this conversation) into a note that keeps its provenance and links back to the source")
    }

    private var scale: CGFloat { isAppendix ? 0.5 : 1 }

    private var font: Font {
        let size: CGFloat = switch paragraph.effectiveHeading {
        case 1: 28
        case 2: 23
        case 3: 19
        default: 17
        }
        return .system(size: size * scale,
                       weight: paragraph.effectiveHeading == nil ? .regular : .bold,
                       design: .serif)
    }
}

/// Flow: dense prose broken open for reading, carried over from Digital
/// Letters. Whitespace runs become line breaks where the surrounding
/// characters say a thought ends — a blank line after a sentence's
/// period, a new line after an in-sentence comma, and around
/// parentheses. Punctuation inside numbers and abbreviations stays put:
/// a period breaks only between a letter and a following capital; a
/// comma never breaks against a digit. The transform edits the composed
/// AttributedString, so links and marks ride along untouched.
nonisolated enum FlowBreaker {
    static func flowed(_ attributed: AttributedString) -> AttributedString {
        let text = Array(String(attributed.characters))
        var replacements: [(start: Int, end: Int, breakText: String)] = []
        var i = 0
        while i < text.count {
            guard text[i] == " " || text[i] == "\t" else { i += 1; continue }
            var j = i
            while j < text.count, text[j] == " " || text[j] == "\t" { j += 1 }
            let before: Character = i > 0 ? text[i - 1] : "\n"
            let beforePrev: Character = i > 1 ? text[i - 2] : "\n"
            let after: Character = j < text.count ? text[j] : "\n"
            let breakText: String? = if before == ".", beforePrev.isLetter, after.isUppercase {
                "\n\n"   // a sentence ended; the next begins
            } else if before == ",", !beforePrev.isNumber, !after.isNumber {
                "\n"     // a clause ended
            } else if before == ")" || after == "(" {
                "\n"     // parentheses stand apart
            } else {
                nil
            }
            if let breakText {
                replacements.append((start: i, end: j, breakText: breakText))
            }
            i = j
        }
        var result = attributed
        for replacement in replacements.reversed() {
            let start = result.index(result.startIndex, offsetByCharacters: replacement.start)
            let end = result.index(result.startIndex, offsetByCharacters: replacement.end)
            result.replaceSubrange(start..<end, with: AttributedString(replacement.breakText))
        }
        return result
    }
}

#Preview("Transcript paragraphs") {
    VStack(alignment: .leading, spacing: 8) {
        ParagraphView(paragraph: LiquidDoc.Paragraph(
            id: "p1", heading: nil,
            text: "Frode Hegland: I think the key is that every statement should be addressable, so a reader can always follow a quote back to the moment it was spoken.",
            speaker: "Frode Hegland"))
        ParagraphView(paragraph: LiquidDoc.Paragraph(
            id: "p2", heading: nil,
            text: "Mark Anderson: Agreed — and the speaker names need to be real people in the system, not just strings.",
            speaker: "Mark Anderson"))
        ParagraphView(paragraph: LiquidDoc.Paragraph(
            id: "p3", heading: nil,
            text: "A plain paragraph without a speaker, for comparison."))
    }
    .padding(20)
    .frame(width: 640)
    .environment(AppState())
}
