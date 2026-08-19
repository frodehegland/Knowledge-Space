import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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

    /// The stretch blocks open in this reading — stretchtext is closed
    /// by default, the words folded behind their `»` until asked for.
    @State private var openStretch: Set<String> = []
    /// How the opened detail reads — a callout behind a quiet rule, or
    /// inline in the flow — per the setting shared across platforms.
    @AppStorage("stretchtextDisplay") private var stretchDisplayRaw =
        StretchtextDisplay.callout.rawValue
    private var stretchDisplay: StretchtextDisplay {
        StretchtextDisplay(rawValue: stretchDisplayRaw) ?? .callout
    }

    /// The sections folded closed — the outline, as in Author. Pinch
    /// in on the trackpad (or ⌘－) folds every section under its
    /// heading; a heading's triangle or click opens its own; pinch
    /// out (or ⌘＋) opens the reading whole. Per reading, like the
    /// stretchtext above.
    @State private var foldedSections: Set<String> = []
    /// One pinch acts once — the flag rests until the fingers lift.
    @State private var pinchActed = false

    var body: some View {
        Group {
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
        // Pinch in folds the reading into its outline; pinch out opens
        // it whole again. The scroll keeps its own gestures.
        .simultaneousGesture(outlinePinch)
        // The View menu's ⌘－/⌘＋ answer the same way while this
        // reading is front — but only when the document has headings
        // to fold under; otherwise the menu keeps its text sizing.
        .focusedSceneValue(\.outlineFold, canOutline
            ? OutlineFoldActions(folded: !foldedSections.isEmpty,
                                 fold: { foldAll() },
                                 unfold: { unfoldAll() })
            : nil)
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
                // The flow walks the body with its stretch blocks
                // grouped: consecutive paragraphs sharing a stretchID —
                // the expandable detail Author's EPUB export writes —
                // fold behind one toggle, closed by default. A folded
                // section's paragraphs step out of the flow entirely;
                // its heading stays and speaks for them.
                let hidden = foldedParagraphIDs
                let items = OrigamiFlowItem.build(body.filter {
                    (state.showsVisualMeta || !appendixIDs.contains($0.id))
                        && !hidden.contains($0.id)
                })
                // The folded opening — the run before any heading —
                // has no heading row of its own; a quiet line stands
                // in for it.
                if let opening = sections.first, opening.heading == nil,
                   foldedSections.contains(opening.id) {
                    openingPlaceholder(opening)
                }
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    switch item {
                    case .paragraph(let paragraph):
                        // The `»` toggle rides inline at the end of the
                        // paragraph the stretch follows — where Author
                        // writes it — when that paragraph is running text.
                        let trailing: (id: String, run: [LiquidDoc.Paragraph])? = {
                            guard Self.canHostStretch(paragraph),
                                  index + 1 < items.count,
                                  case .stretch(let id, let run) = items[index + 1]
                            else { return nil }
                            return (id, run)
                        }()
                        // While the outline is engaged, headings wear
                        // the fold triangle and answer clicks.
                        if paragraph.heading != nil, !foldedSections.isEmpty {
                            headingRow(paragraph, appendixIDs: appendixIDs,
                                       trailingStretch: trailing)
                        } else {
                            paragraphRow(paragraph, appendixIDs: appendixIDs,
                                         trailingStretch: trailing)
                        }
                    case .stretch(let id, let run):
                        let hosted: Bool = {
                            guard index > 0,
                                  case .paragraph(let host) = items[index - 1]
                            else { return false }
                            return Self.canHostStretch(host)
                        }()
                        stretchBlock(id: id, run: run, hosted: hosted,
                                     appendixIDs: appendixIDs)
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
        // A fragment inside a folded section opens the section first,
        // so its paragraph exists to scroll to.
        if let section = sections.first(where: { section in
            section.paragraphs.contains { $0.id == fragment }
        }), foldedSections.contains(section.id) {
            foldedSections.remove(section.id)
        }
        // A fragment inside a closed stretch opens the stretch first,
        // so its paragraph exists to scroll to.
        if let target = doc.body?.first(where: { $0.id == fragment }),
           let stretchID = target.stretchID, !openStretch.contains(stretchID) {
            openStretch.insert(stretchID)
            DispatchQueue.main.async {
                withAnimation { proxy.scrollTo(fragment, anchor: .center) }
            }
        } else {
            withAnimation { proxy.scrollTo(fragment, anchor: .center) }
        }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if state.pendingFragment == fragment {
                state.pendingFragment = nil
            }
        }
    }

    // MARK: Folding into outline

    /// The document sliced at its headings — OrigamiReading's pure
    /// structure, shared with the citation layer.
    private var sections: [OrigamiSection] {
        OrigamiSection.build(from: doc)
    }

    /// Only a document with headings has an outline to fold into —
    /// an EPUB's chapters, a paper's sections. Without one, the pinch
    /// rests and the View menu keeps its text sizing.
    private var canOutline: Bool {
        doc.body?.contains { $0.heading != nil } == true
    }

    /// The paragraphs of every folded section — what steps out of the
    /// reading flow while the outline is engaged.
    private var foldedParagraphIDs: Set<String> {
        guard !foldedSections.isEmpty else { return [] }
        var hidden: Set<String> = []
        for section in sections where foldedSections.contains(section.id) {
            for paragraph in section.paragraphs { hidden.insert(paragraph.id) }
        }
        return hidden
    }

    private func foldAll() {
        guard canOutline else { return }
        withAnimation(.snappy) { foldedSections = Set(sections.map(\.id)) }
    }

    private func unfoldAll() {
        withAnimation(.snappy) { foldedSections = [] }
    }

    private func toggleSection(_ id: String) {
        withAnimation(.snappy) {
            if foldedSections.contains(id) {
                foldedSections.remove(id)
            } else {
                foldedSections.insert(id)
            }
        }
    }

    /// The trackpad's pinch: in folds the reading into its outline,
    /// out opens it whole. Acts once per pinch, at a comfortable
    /// threshold, and never steals the scroll.
    private var outlinePinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard !pinchActed, canOutline else { return }
                if value.magnification < 0.8 {
                    pinchActed = true
                    foldAll()
                } else if value.magnification > 1.25, !foldedSections.isEmpty {
                    pinchActed = true
                    unfoldAll()
                }
            }
            .onEnded { _ in pinchActed = false }
    }

    /// A heading while the outline is engaged: the fold triangle at
    /// its left — the sidebar's own gesture, brought to the page — and
    /// the whole line answering a click.
    private func headingRow(_ paragraph: LiquidDoc.Paragraph,
                            appendixIDs: Set<String>,
                            trailingStretch: (id: String, run: [LiquidDoc.Paragraph])? = nil) -> some View {
        let folded = foldedSections.contains(paragraph.id)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button {
                toggleSection(paragraph.id)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(folded ? 0 : 90))
            }
            .buttonStyle(.plain)
            .help(folded ? "Open this section" : "Fold this section")
            paragraphRow(paragraph, appendixIDs: appendixIDs,
                         trailingStretch: trailingStretch)
        }
        .contentShape(Rectangle())
        .onTapGesture { toggleSection(paragraph.id) }
    }

    /// The folded opening — the run before any heading — has no
    /// heading to stand under; a quiet line holds its place.
    private func openingPlaceholder(_ section: OrigamiSection) -> some View {
        Button {
            toggleSection(section.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                Text("Opening ⋯")
                    .italic()
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open the words before the first heading")
    }

    // MARK: Stretchtext

    /// One paragraph of the flow, rendered per its kind — photo line,
    /// carried image, live table, or text. A `trailingStretch` puts the
    /// stretch toggle at the text's end; `closeStretch` marks a revealed
    /// paragraph, a click anywhere in it folding the stretch again.
    @ViewBuilder
    private func paragraphRow(_ paragraph: LiquidDoc.Paragraph,
                              appendixIDs: Set<String>,
                              trailingStretch: (id: String, run: [LiquidDoc.Paragraph])? = nil,
                              closeStretch: (id: String, isLast: Bool)? = nil) -> some View {
        // A "Photo: <name>" line names an image beside the note in the
        // folder (a scan's capture) — shown as the picture itself,
        // clickable to open full size.
        if let name = Self.photoFileName(in: paragraph.text) {
            photoView(name)
                .id(paragraph.id)
        } else if let image = LiquidDoc.imageReference(in: paragraph.text),
                  let asset = doc.assets.first(where: { $0.id == image.id }) {
            // An imported EPUB's figure: the image travels in the
            // document itself, base64 in the JSON. An Interatlas
            // screenshot carries its citation aboard — or beside it, as
            // Author's export writes it — and answers a click with it.
            OrigamiAssetView(asset: asset,
                             fallback: Self.imageCitation(after: paragraph, in: doc),
                             doc: doc)
                .id(paragraph.id)
        } else if let tableID = paragraph.tableID,
                  let table = doc.tables.first(where: { $0.identifier == tableID }) {
            // A live table from the document's pool; the paragraph's
            // own pipe-text stands in elsewhere.
            OrigamiTableView(table: table, doc: doc, paragraphID: paragraph.id)
                .id(paragraph.id)
        } else {
            ParagraphView(paragraph: paragraph,
                          isAppendix: appendixIDs.contains(paragraph.id),
                          isHighlighted: paragraph.id == state.pendingFragment,
                          flowed: state.flowReading,
                          transcript: paragraph.speaker == nil ? nil : doc,
                          origami: doc,
                          trailingStretch: trailingStretch,
                          closeStretch: closeStretch,
                          openStretchIDs: openStretch,
                          stretchDisplay: stretchDisplay,
                          onToggleStretch: { toggleStretch($0) })
                .id(paragraph.id)
        }
    }

    /// Whether a paragraph is running text — something an inline stretch
    /// toggle can end. Photo lines, images, tables, rules, and multi-line
    /// markdown blocks are not.
    private static func canHostStretch(_ paragraph: LiquidDoc.Paragraph) -> Bool {
        let text = paragraph.displayText
        return paragraph.tableID == nil
            && photoFileName(in: paragraph.text) == nil
            && LiquidDoc.imageReference(in: paragraph.text) == nil
            && !MarkdownBlock.needsRendering(paragraph.text)
            && !(text.count >= 3 && text.allSatisfy { $0 == "-" })
    }

    /// One stretchtext block's detail. Its toggle lives inline in the
    /// host paragraph; only a stretch with no text before it (rare)
    /// gets a toggle of its own here. Open, the detail reads set apart
    /// as a callout behind a quiet rule, or as ordinary paragraphs,
    /// per the shared stretchtext display setting.
    @ViewBuilder
    private func stretchBlock(id: String, run: [LiquidDoc.Paragraph],
                              hosted: Bool, appendixIDs: Set<String>) -> some View {
        let isOpen = openStretch.contains(id)
        if !hosted {
            Button {
                toggleStretch(id)
            } label: {
                Text(isOpen ? "\u{2039}" : "\u{00BB}")
                    .font(.system(size: 17, weight: .bold, design: .serif))
            }
            .buttonStyle(.plain)
            .help(isOpen ? "Close the stretchtext" : "Open the stretchtext")
        }
        // Inline display continues in the host paragraph itself, no
        // break — the block below only renders for callout (or for a
        // hostless stretch, which has no line to continue).
        if isOpen, !(hosted && stretchDisplay == .inline) {
            let content = VStack(alignment: .leading, spacing: 14) {
                ForEach(run) { paragraph in
                    paragraphRow(paragraph, appendixIDs: appendixIDs,
                                 closeStretch: (id, paragraph.id == run.last?.id))
                }
            }
            switch stretchDisplay {
            case .callout:
                content
                    .padding(.leading, 16)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(.quaternary).frame(width: 2)
                    }
            case .inline:
                content
            }
        }
    }

    private func toggleStretch(_ id: String) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if openStretch.contains(id) {
                openStretch.remove(id)
            } else {
                openStretch.insert(id)
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

    // MARK: Image citations

    /// The record an image cites when its citation stands beside it:
    /// Author's export wraps a figure in a citation anchor and repeats
    /// the key in the caption paragraph, so the nearest `[cite:]`
    /// within the two paragraphs after the image is the image's own.
    /// Failing that, a document with exactly one Interatlas-linked
    /// reference gives its images that one — never a guess between
    /// several.
    static func imageCitation(after paragraph: LiquidDoc.Paragraph,
                              in doc: LiquidDoc) -> BibTeXRecord? {
        func record(forKey key: String) -> BibTeXRecord? {
            doc.references.first { $0.id == key }
                .flatMap { BibTeXRecord.records(in: $0.bibtex).first }
        }
        if let body = doc.body,
           let index = body.firstIndex(where: { $0.id == paragraph.id }) {
            for next in body[(index + 1)...].prefix(2) {
                guard let match = next.text.range(of: #"\[cite:([^\]]+)\]"#,
                                                  options: .regularExpression) else { continue }
                let token = String(next.text[match])
                let key = String(token.dropFirst("[cite:".count).dropLast())
                if let found = record(forKey: key) { return found }
            }
        }
        let interatlas = doc.references.compactMap { reference -> BibTeXRecord? in
            guard let parsed = BibTeXRecord.records(in: reference.bibtex).first,
                  let url = parsed.fields["url"],
                  InteratlasLink.isInteratlasLink(url) else { return nil }
            return parsed
        }
        return interatlas.count == 1 ? interatlas.first : nil
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
    /// The document whose pools resolve the Origami reading conventions —
    /// `[cite:key]` to (Author Year) from its references, `[note:id]` to
    /// a dagger, `==marked==` to Author's orange. Nil (or a paragraph
    /// without those tokens) keeps the existing rendering exactly.
    var origami: LiquidDoc? = nil
    /// The body point size to render at, when the context sets one — a
    /// note opened in the list reads one point over its rows. Headings
    /// scale with it; nil keeps the reader's own measure.
    var bodySize: CGFloat? = nil

    /// A stretch block following this paragraph: the `»` toggle rides
    /// inline at the paragraph's end, where Author writes it. Open, the
    /// frame reads ‹ … ›; inline display continues the revealed words
    /// in this same paragraph.
    var trailingStretch: (id: String, run: [LiquidDoc.Paragraph])? = nil
    /// Set on a revealed callout paragraph: a click anywhere in it
    /// folds the stretch again; the last one carries the frame's `›`.
    var closeStretch: (id: String, isLast: Bool)? = nil
    /// The reader's open stretch ids, how open stretchtext displays,
    /// and the reader's answer to a toggle's click.
    var openStretchIDs: Set<String> = []
    var stretchDisplay: StretchtextDisplay = .callout
    var onToggleStretch: ((String) -> Void)? = nil

    private var isRule: Bool {
        let text = paragraph.displayText
        return text.count >= 3 && text.allSatisfy { $0 == "-" }
    }

    /// Whether the text speaks the imported conventions at all — the
    /// cheap gate that keeps every ordinary note on its familiar path.
    private static func hasOrigamiTokens(_ text: String) -> Bool {
        text.contains("[cite:") || text.contains("[note:")
            || text.components(separatedBy: "==").count >= 3
    }

    /// The conventions resolved, then the ordinary inline pipeline —
    /// markdown, live addresses, web links — with marked spans painted
    /// in Author's orange. Citations render in the reader's chosen
    /// style, each a live link that opens the reference's card.
    private static func origamiRendered(_ text: String, in doc: LiquidDoc,
                                        citations style: OrigamiCitationStyle) -> AttributedString {
        var resolved = OrigamiReading.citationsResolved(text, in: doc, style: style,
                                                        linked: true)
        // Endnote tokens become clickable daggers on the origami-note:
        // scheme — a click opens the note in a popover, right where the
        // dagger stands; the notes also read whole at the document's
        // foot, under their Notes heading.
        resolved = OrigamiReading.noteTokensResolved(resolved)
        let parts = resolved.components(separatedBy: "==")
        guard parts.count >= 3, parts.count % 2 == 1 else {
            return LiquidDoc.Paragraph.inlineMarkdown(resolved)
        }
        var out = AttributedString()
        for (index, part) in parts.enumerated() {
            var piece = LiquidDoc.Paragraph.inlineMarkdown(part)
            if index % 2 == 1 {
                piece.foregroundColor = OrigamiReading.markColor
            }
            out += piece
        }
        return out
    }

    /// How citations read — the author's own text, numbered, or
    /// superscript — per the setting shared across platforms. Only the
    /// displayed text changes with it; the citation's link, and the
    /// card a click reveals, are the same in every style.
    @AppStorage("origamiCitationStyle") private var citationStyleRaw =
        OrigamiCitationStyle.authorDate.rawValue
    private var citationStyle: OrigamiCitationStyle {
        OrigamiCitationStyle(rawValue: citationStyleRaw) ?? .authorDate
    }

    private var shownText: AttributedString {
        var rendered: AttributedString
        if let origami, Self.hasOrigamiTokens(paragraph.displayText) {
            rendered = Self.origamiRendered(paragraph.displayText, in: origami,
                                            citations: citationStyle)
        } else {
            rendered = paragraph.renderedText
        }
        if flowed, !isAppendix, paragraph.effectiveHeading == nil {
            rendered = FlowBreaker.flowed(rendered)
        }
        return withStretchAffordances(rendered)
    }

    /// A revealed paragraph's rendered words, for inline display —
    /// the same pipeline as `shownText`, without the affordances.
    private func renderedRun(_ paragraph: LiquidDoc.Paragraph) -> AttributedString {
        if let origami, Self.hasOrigamiTokens(paragraph.displayText) {
            return Self.origamiRendered(paragraph.displayText, in: origami,
                                        citations: citationStyle)
        }
        return paragraph.renderedText
    }

    /// The stretch affordances folded into the paragraph's text: the
    /// inline `»`/`‹` toggle when a stretch block follows, the revealed
    /// words themselves for inline display, and — on a revealed callout
    /// paragraph — a click anywhere folding the stretch again. Stretch
    /// links are controls, not references: they keep the body ink.
    private func withStretchAffordances(_ text: AttributedString) -> AttributedString {
        var out = text
        if let stretch = trailingStretch,
           let url = URL(string: OrigamiReading.stretchScheme + ":" + stretch.id) {
            let isOpen = openStretchIDs.contains(stretch.id)
            let inlineOpen = isOpen && stretchDisplay == .inline
            // Inline and open: the revealed words keep their ink; the
            // host's own words step back so the detail reads apart.
            if inlineOpen { out.foregroundColor = .secondary }
            out += AttributedString(" ")
            var toggle = AttributedString(isOpen ? "\u{2039}" : "\u{00BB}")
            toggle.link = url
            out += toggle
            if inlineOpen {
                for (index, paragraph) in stretch.run.enumerated() {
                    out += AttributedString(" ")
                    out += OrigamiReading.stretchRevealed(
                        renderedRun(paragraph), id: stretch.id,
                        closing: index == stretch.run.count - 1)
                }
            }
        }
        if let closeStretch {
            out = OrigamiReading.stretchRevealed(out, id: closeStretch.id,
                                                 closing: closeStretch.isLast)
        }
        let plain = out.runs.compactMap { run in
            run.link?.scheme == OrigamiReading.stretchScheme
                && run.foregroundColor == nil ? run.range : nil
        }
        for range in plain { out[range].foregroundColor = .primary }
        return out
    }

    /// The endnote a clicked dagger opens, shown in a popover on this
    /// paragraph. Nil between clicks.
    @State private var openNote: LiquidDoc.Paragraph?

    /// The reference a clicked citation reveals, shown in a popover on
    /// this paragraph. Nil between clicks.
    @State private var openCitation: LiquidDoc.Reference?

    /// Catches a stretch toggle's origami-stretch: link, a citation's
    /// origami-cite: link, and a dagger's origami-note: link; everything
    /// else passes through to the window's own handling (origamitext://,
    /// the web).
    private func handleReaderURL(_ url: URL) -> OpenURLAction.Result {
        if url.scheme == OrigamiReading.stretchScheme, let onToggleStretch {
            let raw = String(url.absoluteString.dropFirst(
                OrigamiReading.stretchScheme.count + 1))
            onToggleStretch(raw.removingPercentEncoding ?? raw)
            return .handled
        }
        if let origami, let key = OrigamiReading.citationKey(from: url) {
            openCitation = origami.references.first { $0.id == key }
            return .handled
        }
        guard let origami, let id = OrigamiReading.noteID(from: url) else {
            return .systemAction
        }
        openNote = OrigamiReading.endnote(withID: id, in: origami)
        return .handled
    }

    /// The clicked citation's card: the cited work as the document's
    /// own record tells it — title, who and when, where it appeared,
    /// the abstract when anyone recorded one — and Open, which finds
    /// the nearest copy: the work on the shelf (an imported EPUB reads
    /// right here), its PDF in the Reader Library, or the DOI or web
    /// page last. The same card in every citation style.
    @ViewBuilder private func citationPopover(_ reference: LiquidDoc.Reference) -> some View {
        let record = BibTeXRecord.records(in: reference.bibtex).first
        VStack(alignment: .leading, spacing: 6) {
            if let record {
                Text(record.title.isEmpty ? reference.id : record.title)
                    .font(.system(size: 14, weight: .semibold, design: .serif))
                let credit = [record.displayAuthors, record.year]
                    .filter { !$0.isEmpty }
                    .joined(separator: ", ")
                if !credit.isEmpty {
                    Text(credit)
                        .font(.system(size: 13, design: .serif))
                }
                if let venue = record.fields["journal"]
                    ?? record.fields["booktitle"]
                    ?? record.fields["publisher"] {
                    Text(venue)
                        .font(.system(size: 12, design: .serif))
                        .italic()
                        .foregroundStyle(.secondary)
                }
                if let abstract = state.citedWorkAbstract(of: record) {
                    Text(abstract)
                        .font(.system(size: 12, design: .serif))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                        .lineLimit(10)
                        .padding(.top, 2)
                }
                if state.canOpenCitedWork(record) {
                    Button("Open") { state.openCitedWork(record) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .font(.system(size: 12))
                        .padding(.top, 2)
                        .help("Opens the nearest copy: the work on the shelf, its PDF in the Reader Library, or its DOI or web page")
                }
            } else {
                // A record that does not parse still shows verbatim —
                // the BibTeX is the record.
                Text(reference.bibtex)
                    .font(.system(size: 11, design: .monospaced))
            }
        }
        .textSelection(.enabled)
        .padding(14)
        .frame(minWidth: 240, maxWidth: 380, alignment: .leading)
    }

    /// The dagger's popover: the note's own words, its conventions
    /// resolved like any paragraph's.
    @ViewBuilder private func notePopover(_ note: LiquidDoc.Paragraph) -> some View {
        Text(origami.map { Self.hasOrigamiTokens(note.displayText)
                ? Self.origamiRendered(note.displayText, in: $0, citations: citationStyle)
                : note.renderedText } ?? note.renderedText)
            .font(.system(size: 14, design: .serif))
            .lineSpacing(4)
            .textSelection(.enabled)
            .padding(14)
            .frame(minWidth: 220, maxWidth: 380, alignment: .leading)
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
                    .environment(\.openURL, OpenURLAction { handleReaderURL($0) })
                    .popover(item: $openNote) { note in notePopover(note) }
                    .popover(item: $openCitation) { reference in citationPopover(reference) }
                Spacer(minLength: 0)
            }
            .padding(4)
            .background(isHighlighted ? Color.yellow.opacity(0.35) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 4))
            .animation(.easeOut(duration: 0.6), value: isHighlighted)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                // A paragraph pasted as a whole markdown block — several
                // lines, list items, or a heading beyond the per-line
                // parse's reach — is laid out block by block; the ordinary
                // single line keeps its existing, already-correct path.
                if MarkdownBlock.needsRendering(paragraph.text) {
                    MarkdownBlocksView(text: paragraph.text, scale: scale,
                                       flowed: flowed && !isAppendix)
                } else {
                    Text(shownText)
                        .font(font)
                        // Headings wear the theme's own heading ink,
                        // as Author paints them.
                        .foregroundStyle(paragraph.effectiveHeading == nil
                            ? AppGreys.text : AppGreys.heading)
                        .lineSpacing((paragraph.effectiveHeading == nil ? 6 : 3) * scale)
                        .environment(\.openURL, OpenURLAction { handleReaderURL($0) })
                        .popover(item: $openNote) { note in notePopover(note) }
                        .popover(item: $openCitation) { reference in citationPopover(reference) }
                }
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
        // A context-set body size scales the whole scheme, headings in
        // proportion.
        let factor = (bodySize ?? 17) / 17
        return .system(size: size * factor * scale,
                       weight: paragraph.effectiveHeading == nil ? .regular : .bold,
                       design: .serif)
    }
}

/// An image a document carries aboard (an imported EPUB's figure),
/// its alt text as a quiet caption. An Interatlas screenshot carries
/// its View Citation inside the PNG itself; such an image answers a
/// click with the citation and Open Source — the Interatlas Link that
/// recreates the very scene.
struct OrigamiAssetView: View {
    @Environment(AppState.self) private var state
    let asset: LiquidDoc.Asset
    /// The citation standing beside the image in the document, for a
    /// PNG whose own embedded copy did not survive its export.
    var fallback: BibTeXRecord? = nil
    /// The document the figure stands in, for the package's own scene
    /// datasets (data/<scene-id>.liquidinfo.json, spec §2.4).
    var doc: LiquidDoc? = nil

    /// The citation read out of the PNG, once, on appearance.
    @State private var record: BibTeXRecord?
    /// The complete `.liquidinfo` scene a Liquid PNG carries in its
    /// `liquid-scene` chunk — the image as its own source of truth.
    @State private var scene: String?
    @State private var showsCitation = false

    /// Open Source, each platform through its own door: the Mac probes
    /// the interatlas:// scheme then the chosen app (Settings ▸
    /// Library); iOS and visionOS try the scheme and fall back to the
    /// https link — the browser until Interatlas registers its domain.
    private func openSource(_ url: URL) {
        // The reader may hold nothing but this image: a Liquid view
        // link that does not itself carry the scene is handed over
        // with the scene the document holds — the package's data/
        // file or the PNG's own `liquid-scene` chunk — so what is
        // sent is always enough to re-create the very view. A scene
        // over the link ceiling travels as a `.liquidinfo` file
        // instead (SCENE-DATA-IN-EPUB.md).
        var url = url
        var sceneAsFile: String?
        if LiquidViewLink.isLiquidViewLink(url), let scene {
            if LiquidViewLink.sceneTravelsInLink(scene) {
                url = LiquidViewLink.carryingScene(url, sceneJSON: scene)
            } else if !LiquidViewLink.carriesScene(url) {
                sceneAsFile = scene
            }
        }
        copyHandoffForTesting(url, fileScene: sceneAsFile)
        #if os(macOS)
        if let sceneAsFile {
            state.openLiquidScene(json: sceneAsFile, link: url)
            return
        }
        // The Liquid check first: a Liquid view link lives on the same
        // link domain as Interatlas, told apart by its /liquid/ path.
        if LiquidViewLink.isLiquidViewLink(url) {
            state.openLiquidViewLink(url)
        } else if InteratlasLink.isInteratlasLink(url) {
            state.openInteratlasLink(url)
        } else {
            NSWorkspace.shared.open(url)
        }
        #else
        let schemed = LiquidViewLink.isLiquidViewLink(url)
            ? LiquidViewLink.schemed(url)
            : InteratlasLink.isInteratlasLink(url) ? InteratlasLink.schemed(url) : nil
        if let schemed {
            UIApplication.shared.open(schemed, options: [:]) { accepted in
                if !accepted {
                    UIApplication.shared.open(url)
                }
            }
        } else {
            UIApplication.shared.open(url)
        }
        #endif
    }

    /// A testing aid, documented in LIQUID-OPEN-SOURCE-HANDOFF.md:
    /// everything the hand-off sends, onto the clipboard — the exact
    /// link, its scheme forms, and the scene decoded back out of the
    /// link itself, so the receiving side can be diffed against what
    /// truly travelled. Remove once the hand-off is trusted.
    private func copyHandoffForTesting(_ url: URL, fileScene: String? = nil) {
        var text = "=== Open Source hand-off ===\nlink: \(url.absoluteString)\n"
        if let fileScene {
            text += "scene: too large for the link — sent as a .liquidinfo file (\(fileScene.count) chars):\n\(fileScene)\n"
        } else if LiquidViewLink.isLiquidViewLink(url) {
            for schemed in LiquidViewLink.schemedForms(url) {
                text += "scheme form: \(schemed.absoluteString)\n"
            }
            if let sceneJSON = LiquidViewLink.sceneJSON(from: url) {
                text += "scene (decoded from the link, \(sceneJSON.count) chars):\n\(sceneJSON)\n"
            } else {
                text += "scene: none aboard the link\n"
            }
        } else if InteratlasLink.isInteratlasLink(url),
                  let schemed = InteratlasLink.schemed(url) {
            text += "scheme form: \(schemed.absoluteString)\n"
        }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if record != nil {
                Button {
                    showsCitation = true
                } label: {
                    imageContent
                }
                .buttonStyle(.plain)
                .help("This image carries its citation — click for the record and Open Source")
                .popover(isPresented: $showsCitation) { citationPopover }
            } else {
                imageContent
            }
            if let alt = asset.alt, !alt.isEmpty {
                Text(alt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            // The PNG's own embedded citation first; the one standing
            // beside the image in the document otherwise. The scene
            // rides along for Open Source, by the format's ladder:
            // the package's data/ file is the full truth — the chunk
            // may be the trimmed form when the data is large — and
            // the chunk stands in otherwise.
            if asset.mediaType == "image/png", let data = asset.data {
                scene = PNGCitation.sceneText(inPNGData: data)
                if let text = PNGCitation.citationText(inPNGData: data),
                   let found = BibTeXRecord.records(in: text).first {
                    record = found
                }
            }
            if record == nil { record = fallback }
            if let packaged = packagedScene() { scene = packaged }
        }
    }

    /// The scene dataset the document's package carries for this
    /// figure (spec §2.4) — named by the citation's `scene-resource`
    /// field (the pool's copy carries it; the PNG's embedded record
    /// cannot know package paths), or matched to the link's scene id
    /// when the field is absent.
    private func packagedScene() -> String? {
        guard let doc else { return nil }
        var names: [String] = []
        if let resource = record?.fields["scene-resource"]
            ?? fallback?.fields["scene-resource"] {
            let trimmed = resource.trimmingCharacters(in: .whitespaces)
            names.append((trimmed as NSString).lastPathComponent.lowercased())
        }
        if let urlText = record?.fields["url"] ?? fallback?.fields["url"],
           let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)),
           LiquidViewLink.isLiquidViewLink(url),
           let sceneID = url.pathComponents.last, !sceneID.isEmpty {
            names.append("\(sceneID.lowercased()).liquidinfo.json")
        }
        guard !names.isEmpty else { return nil }
        for candidate in doc.assets
        where candidate.isLiquidSceneResource
            && names.contains(candidate.filename.lowercased()) {
            if let data = candidate.data {
                return String(data: data, encoding: .utf8)
            }
        }
        return nil
    }

    @ViewBuilder private var imageContent: some View {
        #if os(macOS)
        if let data = asset.data, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 480, maxHeight: 480, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Label(asset.filename, systemImage: "photo")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        #else
        if let data = asset.data, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 480, maxHeight: 480, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Label(asset.filename, systemImage: "photo")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        #endif
    }

    /// The citation as the source pages speak it, with its doors.
    @ViewBuilder private var citationPopover: some View {
        if let record {
            VStack(alignment: .leading, spacing: 10) {
                Text(record.citationSentence)
                    .font(.system(size: 14, design: .serif))
                    .textSelection(.enabled)
                if let abstract = record.fields["abstract"], !abstract.isEmpty {
                    Text(abstract)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack(spacing: 8) {
                    if let urlText = record.fields["url"],
                       let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)) {
                        Button("Open Source") { openSource(url) }
                            .help(LiquidViewLink.isLiquidViewLink(url)
                                  ? "Opens this very view in Liquid — the link carries the whole view state"
                                  : InteratlasLink.isInteratlasLink(url)
                                  ? "Opens this very scene in Interatlas — the link carries the whole view state"
                                  : "Opens the cited source")
                    }
                    Button("Copy Citation") {
                        #if os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(record.raw, forType: .string)
                        #else
                        UIPasteboard.general.string = record.raw
                        #endif
                    }
                    .help("The full BibTeX record, onto the clipboard")
                }
            }
            .padding(14)
            .frame(minWidth: 260, maxWidth: 420, alignment: .leading)
        }
    }
}

/// A live table from an imported document's pool: the computed cell
/// values in a plain grid, first row read as the header. The paragraph
/// standing for the table keeps a pipe-text rendering, so nothing is
/// lost where this view is not used.
struct OrigamiTableView: View {
    let table: LiquidDoc.Table
    /// The document and table paragraph this grid stands in. With both
    /// given, the reader's what-ifs persist as "editing" annotations in
    /// the document's sidecar; without them (the Settings preview) the
    /// numbers live only as long as the view.
    var doc: LiquidDoc? = nil
    var paragraphID: String? = nil

    @Environment(AppState.self) private var state
    /// The table's dress — Settings ▸ Tables.
    @AppStorage("tableStyle") private var tableStyleRaw = TableStyle.greyBackground.rawValue
    /// The reader's what-ifs: numbers typed over the inputs, keyed
    /// "row,col" — the reader's annotation, never the document's words.
    @State private var overrides: [String: String] = [:]
    /// What the sidecar last heard, so loading is never re-saved and
    /// saving happens a beat after the typing rests.
    @State private var savedEdits: [String: String] = [:]
    @State private var saveTask: Task<Void, Never>?

    private var style: TableStyle {
        TableStyle(rawValue: tableStyleRaw) ?? .greyBackground
    }

    /// A table with formulas reads live: its computed cells follow the
    /// inputs, and the inputs answer to a click.
    private var live: Bool { TableMath.hasMath(table) }

    var body: some View {
        let computed = TableMath.computedGrid(table, overrides: overrides)
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                    ForEach(Array(table.cells.enumerated()), id: \.offset) { row, cells in
                        GridRow {
                            ForEach(Array(cells.enumerated()), id: \.offset) { col, cell in
                                cellView(cell, row: row, col: col, computed: computed)
                            }
                        }
                        if row == 0 && table.cells.count > 1 {
                            Divider()
                        }
                    }
                }
                .padding(10)
            }
            // Only the way back, and only once there is one: Reset,
            // quiet under the grid, returns the document's numbers.
            if live, !overrides.isEmpty {
                Button("Reset") {
                    withAnimation(.snappy) { overrides = [:] }
                }
                .buttonStyle(.link)
                .font(.caption)
                .help("Back to the document's own numbers — your tried numbers leave the annotation")
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
        .background {
            if style == .greyBackground {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary.opacity(0.4))
            }
        }
        .overlay {
            if style == .lightFrame {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.quaternary)
            }
        }
        // The what-ifs come back with the reading, and every change
        // rests a moment before the sidecar hears it.
        .onAppear {
            guard let doc, let paragraphID else { return }
            let kept = state.tableEdits(for: doc, paragraphID: paragraphID)
            overrides = kept
            savedEdits = kept
        }
        .onChange(of: overrides) {
            guard let doc, let paragraphID, overrides != savedEdits else { return }
            saveTask?.cancel()
            let edits = overrides
            saveTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return }
                state.setTableEdits(edits, for: doc, paragraphID: paragraphID)
                savedEdits = edits
            }
        }
    }

    /// One cell: a computed cell shows its result (the formula rides
    /// on the pointer), an input cell in a live table is editable in
    /// place, and everything else is the words as written.
    @ViewBuilder
    private func cellView(_ cell: LiquidDoc.Table.Cell, row: Int, col: Int,
                          computed: [String: String]) -> some View {
        let key = "\(row),\(col)"
        if let formula = TableMath.formula(of: cell) {
            Text(computed[key] ?? cell.value)
                .font(cellFont(row: row))
                // A computed cell whispers what it is: a dotted line
                // under the number, the formula on the pointer.
                .underline(pattern: .dot, color: .secondary.opacity(0.5))
                .help(formula.hasPrefix("=") ? formula : "= " + formula)
                .contentTransition(.numericText())
                .animation(.snappy, value: computed[key])
        } else if live, TableMath.numeric(cell.value) != nil {
            TextField("", text: overrideBinding(key, original: cell.value))
                .textFieldStyle(.plain)
                .font(cellFont(row: row))
                .fixedSize()
                .foregroundStyle(overrides[key] == nil
                                 ? AnyShapeStyle(.primary)
                                 : AnyShapeStyle(Color.accentColor))
                .help("An input the maths reads — try another number; Reset restores the document's.")
        } else {
            Text(cell.value)
                .font(cellFont(row: row))
                .textSelection(.enabled)
        }
    }

    private func cellFont(row: Int) -> Font {
        .system(size: 14, weight: row == 0 ? .semibold : .regular, design: .serif)
    }

    /// Typing over an input keeps the what-if beside the document's
    /// own number; typing the original back lets the what-if go.
    private func overrideBinding(_ key: String, original: String) -> Binding<String> {
        Binding(
            get: { overrides[key] ?? original },
            set: { text in
                if text == original || text.isEmpty {
                    overrides.removeValue(forKey: key)
                } else {
                    overrides[key] = text
                }
            })
    }
}

/// A block of pasted markdown the reader lays out itself. The per-line
/// parse already turns "# ", "## ", "### " lines into headings and renders
/// inline bold/italic; what it leaves literal — list markers, headings
/// beyond H3, and any whole block pasted into a single paragraph — is
/// interpreted here for display only. The file keeps its plain markdown.
private struct MarkdownBlock: Identifiable {
    enum Kind: Equatable { case heading(Int), bullet, ordered(Int), rule, prose }
    let id = UUID()
    let kind: Kind
    let text: String

    /// A single line carrying an unordered ("- ", "* ", "+ ") or ordered
    /// ("3. ") list marker.
    static func isListLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces)
            .range(of: #"^([-*+]\s+|\d+\.\s+)"#, options: .regularExpression) != nil
    }

    /// Whether a paragraph's text carries block markdown the per-line parse
    /// did not resolve: more than one line, a list marker, or a heading
    /// prefix still literal in the text (the structured H1–H3 case has its
    /// prefix stripped already, so it stays on the plain path).
    static func needsRendering(_ text: String) -> Bool {
        text.contains("\n")
            || isListLine(text)
            || text.trimmingCharacters(in: .whitespaces).hasPrefix("#")
    }

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil {
                blocks.append(.init(kind: .rule, text: ""))
            } else if let m = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                let level = min(line[..<m.upperBound].filter { $0 == "#" }.count, 6)
                blocks.append(.init(kind: .heading(level),
                                    text: String(line[m.upperBound...]).trimmingCharacters(in: .whitespaces)))
            } else if let m = line.range(of: #"^[-*+]\s+"#, options: .regularExpression) {
                blocks.append(.init(kind: .bullet, text: String(line[m.upperBound...])))
            } else if let m = line.range(of: #"^(\d+)\.\s+"#, options: .regularExpression) {
                let number = Int(line[..<m.upperBound].filter(\.isNumber)) ?? 1
                blocks.append(.init(kind: .ordered(number), text: String(line[m.upperBound...])))
            } else {
                blocks.append(.init(kind: .prose, text: line))
            }
        }
        return blocks
    }
}

/// Lays out a paragraph's markdown as blocks — headings (H1–H6), unordered
/// and ordered lists with a hanging indent, rules, and prose — each block's
/// own words carrying inline bold/italic and live links.
private struct MarkdownBlocksView: View {
    let text: String
    let scale: CGFloat
    let flowed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            ForEach(MarkdownBlock.parse(text)) { block in
                switch block.kind {
                case .rule:
                    Divider()
                case .heading(let level):
                    Text(LiquidDoc.Paragraph.inlineMarkdown(block.text))
                        .font(.system(size: headingSize(level) * scale, weight: .bold, design: .serif))
                case .bullet:
                    listRow("•", block.text)
                case .ordered(let number):
                    listRow("\(number).", block.text)
                case .prose:
                    Text(prose(block.text))
                        .font(.system(size: 17 * scale, design: .serif))
                        .lineSpacing(6 * scale)
                }
            }
        }
    }

    private func prose(_ text: String) -> AttributedString {
        let rendered = LiquidDoc.Paragraph.inlineMarkdown(text)
        return flowed ? FlowBreaker.flowed(rendered) : rendered
    }

    private func listRow(_ marker: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8 * scale) {
            Text(marker)
                .font(.system(size: 17 * scale, design: .serif))
                .foregroundStyle(.secondary)
                .frame(minWidth: 16 * scale, alignment: .trailing)
            Text(LiquidDoc.Paragraph.inlineMarkdown(text))
                .font(.system(size: 17 * scale, design: .serif))
                .lineSpacing(6 * scale)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 6 * scale)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 28
        case 2: 23
        case 3: 19
        case 4: 17
        case 5: 16
        default: 15
        }
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

/// The fold-into-outline actions the front reading offers the View
/// menu: ⌘－ folds every section under its heading, ⌘＋ opens the
/// reading whole — as in Author. Nil while no reading with headings
/// is front, so the menu keeps its text sizing.
struct OutlineFoldActions {
    let folded: Bool
    let fold: () -> Void
    let unfold: () -> Void
}

extension FocusedValues {
    @Entry var outlineFold: OutlineFoldActions?
}
