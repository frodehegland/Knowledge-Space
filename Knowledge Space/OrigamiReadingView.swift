import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Ported from Augmented Library's OrigamiReadingView.swift (macOS) —
// the book reader: an Origami document read natively in the reader's
// chosen view style — article, outline, focus, transcript — with the
// reading menu on every paragraph, W3C highlights and comments in
// sidecars, the glossary's four displays, progressive folding, flow
// reading, and the on-device reading functions. Keep the shared parts
// synced; a fix here should be carried back.
//
// Knowledge Space adaptations, each marked "KS:" where it lands:
//  - LibraryModel → AppState (annotations live beside the document's
//    file; citations open through the EPUB Library's own resolvers).
//  - ReadingTheme → the app's themes (AppGreys), which already answer
//    for light and dark.
//  - ⌘−/⌘+ (fold) and ⌘⇧±/⌥⌘± (type) route through the View menu via
//    focused values instead of hidden buttons.
//  - KS additions: the chrome bar (style picker, contents, section
//    stepping, Aa), the two-page spread in Focus, fold-to-concepts and
//    fold-to-names, the cover opening, and reading-progress memory.

/// The fold-into-outline verbs and the type-setting verbs a reading
/// offers the View menu while it is front.
struct ReadingTypographyActions {
    let bigger: () -> Void
    let smaller: () -> Void
    let looser: () -> Void
    let tighter: () -> Void
}

extension FocusedValues {
    @Entry var readingTypography: ReadingTypographyActions?
    /// The front reading's printable book — its .epub on disk — for
    /// File ▸ Print Booklet…; nil while nothing front can print.
    @Entry var bookletSource: URL?
}

// MARK: - KS: the annotations' home

/// Annotations live in a JSON-LD sidecar beside the document's own file
/// in the community folder — `<id>.annotations.jsonld` — the reader's
/// notes, never written into the author's document.
extension AppState {
    func annotations(for doc: LiquidDoc) -> [WebAnnotation] {
        _ = annotationsStamp
        return AnnotationStore.load(for: doc.id,
                                    in: doc.fileURL.deletingLastPathComponent())
    }

    func addHighlight(to doc: LiquidDoc, paragraphID: String, exact: String? = nil) {
        let annotation = WebAnnotation(
            motivation: WebAnnotation.Motivation.highlighting,
            target: AnnotationAnchor.target(in: doc, paragraphID: paragraphID,
                                            exact: exact))
        appendAnnotation(annotation, for: doc)
    }

    func addComment(_ text: String, to doc: LiquidDoc, paragraphID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let annotation = WebAnnotation(
            motivation: WebAnnotation.Motivation.commenting,
            body: WebAnnotation.TextualBody(value: trimmed),
            target: AnnotationAnchor.target(in: doc, paragraphID: paragraphID))
        appendAnnotation(annotation, for: doc)
    }

    func removeAnnotation(_ annotation: WebAnnotation, for doc: LiquidDoc) {
        let folder = doc.fileURL.deletingLastPathComponent()
        var annotations = AnnotationStore.load(for: doc.id, in: folder)
        annotations.removeAll { $0.id == annotation.id }
        AnnotationStore.save(annotations, for: doc.id, in: folder)
        annotationsStamp += 1
    }

    private func appendAnnotation(_ annotation: WebAnnotation, for doc: LiquidDoc) {
        let folder = doc.fileURL.deletingLastPathComponent()
        var annotations = AnnotationStore.load(for: doc.id, in: folder)
        annotations.append(annotation)
        AnnotationStore.save(annotations, for: doc.id, in: folder)
        annotationsStamp += 1
    }
}

// MARK: - The reader

struct OrigamiReadingView: View {
    @Environment(AppState.self) private var state   // KS: was LibraryModel
    let doc: LiquidDoc

    /// KS: Author's foot modes — Scroll is the article flow; Horizontal
    /// is pages side by side, two at least, a page more for every 460
    /// points the window offers.
    @AppStorage("readerMode") private var readerModeRaw = ReaderMode.scroll.rawValue

    enum ReaderMode: String, CaseIterable {
        case scroll, horizontal, focus
    }

    private var readerMode: ReaderMode {
        ReaderMode(rawValue: readerModeRaw) ?? .scroll
    }

    @AppStorage("origamiCitationStyle") private var citationsRaw =
        OrigamiCitationStyle.authorDate.rawValue
    @AppStorage("origamiContextActions") private var actionsRaw =
        OrigamiContextAction.encodeList(OrigamiContextAction.defaultActions)
    /// KS: "Open sources in" — a tapped citation auto-opens its cited
    /// source in the preferred medium; Always Ask shows the card.
    @AppStorage("openSourcesIn") private var openSourcesIn = "ask"
    /// KS: the LaTeX profile from Settings ▸ LaTeX — when on, its
    /// decisions dress the reading: the class size and leading, the
    /// \textwidth measure, the packages' roman, justified paragraphs
    /// indented at \parindent.
    @AppStorage(LaTeXStyleProfile.enabledKey) private var latexOn = false
    @AppStorage(LaTeXStyleProfile.storageKey) private var latexRaw = ""

    private var latex: LaTeXStyleProfile? {
        latexOn ? LaTeXStyleProfile.decode(latexRaw) : nil
    }

    @AppStorage("readingAIPrompts") private var aiPromptsRaw =
        AIPromptPreset.encodeList(AIPromptPreset.defaultPresets)
    @AppStorage("readingBodyFont") private var bodyFontName = "New York"
    @AppStorage("readingHeadingFont") private var headingFontName = "New York"
    /// Points added to (or taken from) every reading size — ⌘⇧+ and
    /// ⌘⇧−. One value for all windows, kept until changed.
    @AppStorage("readingFontDelta") private var fontDelta = 3.0
    /// Extra points between lines — ⌥⌘+ and ⌥⌘−. Shared and kept the
    /// same way.
    @AppStorage("readingLineSpacing") private var lineSpacing = 3.0
    @AppStorage("stretchtextDisplay") private var stretchDisplayRaw =
        StretchtextDisplay.callout.rawValue
    @AppStorage("glossaryDisplay") private var glossaryDisplayRaw =
        GlossaryDisplay.hidden.rawValue
    @AppStorage("markedTextStyle") private var markedStyleRaw = MarkedTextStyle.orange.rawValue
    /// Engelbart's grammar-of-the-view: colour code words by part of
    /// speech or named entity.
    @AppStorage("textColoringMode") private var coloringModeRaw = TextColoringMode.off.rawValue
    @AppStorage("textColorRules") private var colorRulesRaw =
        TextColorRule.encodeList(TextColorRule.defaultRules)
    @Environment(\.colorScheme) private var colorScheme

    private var coloringMode: TextColoringMode {
        TextColoringMode(rawValue: coloringModeRaw) ?? .off
    }

    /// Author's full-screen measure: the text column as a percentage
    /// of the display's width, one value for the built-in display and
    /// one for an external.
    @AppStorage("fullScreenWidthInternal") private var fullScreenWidthInternal = 67.0
    @AppStorage("fullScreenWidthExternal") private var fullScreenWidthExternal = 45.0
    /// KS: the windowed measure, Wider/Narrower in the Aa popover.
    @AppStorage("readingMeasure") private var windowedMeasure = 680.0
    @State private var windowState = ReaderWindowState()

    /// The reading column's width: the chosen points in a window; in
    /// full screen, the chosen percentage of this display's width. A
    /// LaTeX profile's \textwidth is the measure wherever the window
    /// stands — that is the point of it.
    private var measure: CGFloat {
        if let width = latex?.textWidth { return CGFloat(width) }
        guard windowState.isFullScreen else { return CGFloat(windowedMeasure) }
        let percent = windowState.isBuiltInDisplay
            ? fullScreenWidthInternal : fullScreenWidthExternal
        return max(windowState.screenWidth * percent / 100, 300)
    }

    private var markedStyle: MarkedTextStyle {
        MarkedTextStyle(rawValue: Int(markedStyleRaw)) ?? .orange
    }

    /// Any stretchtext open puts the reader in stretch focus: the
    /// revealed text keeps its ink, everything else reads grey.
    private var stretchFocus: Bool { !openStretch.isEmpty }

    private var stretchDisplay: StretchtextDisplay {
        StretchtextDisplay(rawValue: stretchDisplayRaw) ?? .callout
    }

    private var glossaryDisplay: GlossaryDisplay {
        GlossaryDisplay(rawValue: glossaryDisplayRaw) ?? .hidden
    }

    @State private var focusIndex = 0
    @State private var collapsed: Set<String> = []
    @State private var openStretch: Set<String> = []
    @State private var commentTarget: CommentTarget?
    @State private var conceptTarget: LiquidDoc.Concept?
    @State private var citationTarget: CitationTarget?
    @State private var noteTarget: NoteTarget?
    @State private var showReferences = false
    /// A selection being viewed differently — Flow lines or an AI
    /// rewrite. While set, everything unselected reads grey and any
    /// click on the grey returns to normal.
    @State private var selectionMode: SelectionViewMode?
    /// The glossary definitions currently unfolded, by concept id
    /// (the Icon display's daggers).
    @State private var openGlossary: Set<String> = []
    /// How far the document is folded (⌘− folds, ⌘+ unfolds): 0 reads
    /// whole; 1 is headings, first sentences, and Marked lines; deeper
    /// levels are headings alone, then fewer ranks of them.
    @State private var foldLevel = 0
    /// Sections clicked open while folded, by heading id.
    @State private var expandedFold: Set<String> = []
    /// KS: what the fold shows under its headings — nothing (the
    /// headings alone speak), the sections' Defined Concepts, or the
    /// people named. Author's alternate pinch targets.
    @AppStorage("readingFoldTarget") private var foldTargetRaw = FoldTarget.headings.rawValue
    /// The Tab glossary overview: text grey, terms Marked, definitions
    /// a click away. Tab again returns to normal reading.
    @State private var glossaryOverviewOn = false
    @State private var tabMonitor: Any?
    /// The moment's confirmation line at the window's foot.
    @State private var keepNotice: String?
    // The reading functions: the text expanded into meaning-paragraphs
    // (p), broken into flow lines (f), and each paragraph's key
    // sentence bolded (b).
    @State private var expandParagraphs = false
    @State private var flowReading = false
    @State private var boldKeySentences = false
    /// The model's paragraph breaks, cached per paragraph id — the
    /// text with blank lines at the meaning shifts (or unchanged when
    /// the model found none).
    @State private var paragraphSplits: [String: String] = [:]
    /// The model's key sentence per paragraph id, cached — empty where
    /// it chose none, so a paragraph is never asked twice.
    @State private var keySentences: [String: String] = [:]
    @State private var keyMonitor: Any?
    @AppStorage("flowBreakOnComma") private var flowBreakOnComma = true
    @AppStorage("flowDoubleBreakOnPeriod") private var flowDoubleBreakOnPeriod = false
    @State private var pinchMonitor: Any?
    @State private var pinchAccumulator: CGFloat = 0
    /// KS: two-finger page turns in Horizontal — the swipe's travel,
    /// one turn per gesture, and the reading area's live width (the
    /// page count follows it).
    @State private var swipeMonitor: Any?
    @State private var swipeAccumulatorX: CGFloat = 0
    @State private var swipeTurned = false
    @State private var horizontalViewWidth: CGFloat = 0
    /// KS: the table of contents popover.
    @State private var showContents = false
    /// KS: where the next layout pass should land — a heading id from
    /// the contents, a fold toggle, or an arriving fragment.
    @State private var pendingScrollID: String?
    /// KS: the section the contents last visited, in the Write flow.
    @State private var steppedIndex = 0
    /// KS: reading-progress memory (article style): the scroll offset,
    /// saved a moment after every move and restored on return.
    @State private var scrollPosition = ScrollPosition()
    @State private var progressSaveTask: Task<Void, Never>?

    enum FoldTarget: String, CaseIterable, Identifiable {
        case headings, concepts, names
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .headings: "Headings"
            case .concepts: "Concepts"
            case .names: "Names"
            }
        }
    }

    private var foldTarget: FoldTarget {
        FoldTarget(rawValue: foldTargetRaw) ?? .headings
    }

    private struct CommentTarget: Identifiable {
        let paragraphID: String
        let preview: String
        var id: String { paragraphID }
    }

    private struct CitationTarget: Identifiable {
        let key: String
        var id: String { key }
    }

    private struct NoteTarget: Identifiable {
        let noteID: String
        var id: String { noteID }
    }

    private var citationStyle: OrigamiCitationStyle {
        OrigamiCitationStyle(rawValue: citationsRaw) ?? .authorDate
    }

    // MARK: - Theme (KS: the app's own)

    private var themeText: Color? { AppGreys.text }
    private var themeHeading: Color? { AppGreys.heading }
    private var themeDimmed: Color? { AppGreys.quietText }

    /// A paragraph's ink for the AppKit text view.
    private func inkColor(for paragraph: LiquidDoc.Paragraph) -> NSColor? {
        let color = paragraph.heading != nil ? themeHeading : themeText
        return color.map(NSColor.init)
    }

    /// A heading or paragraph rendered with the document's conventions —
    /// citations in the reader's style, then the inline markdown.
    private func rendered(_ text: String) -> AttributedString {
        OrigamiReading.inlineAttributed(text, in: doc, citations: citationStyle,
                                        markStyle: markedStyle, appearance: colorScheme)
    }

    private var enabledActions: [OrigamiContextAction] {
        OrigamiContextAction.decodeList(actionsRaw)
    }

    private var sections: [OrigamiSection] { OrigamiSection.build(from: doc) }

    var body: some View {
        let annotations = resolvedByParagraph
        ScrollViewReader { proxy in
            Group {
                if foldLevel > 0,
                   let folded = OrigamiReading.folded(doc, level: foldLevel,
                                                      expanded: expandedFold) {
                    foldedView(folded, annotations: annotations)
                } else {
                    switch readerMode {
                    case .scroll: articleView(annotations)
                    case .horizontal: horizontalView(annotations)
                    case .focus: focusView(annotations)
                    }
                }
            }
            // KS: the contents, the fold toggles, and arriving
            // fragments all land through one door, after layout.
            .onChange(of: pendingScrollID) {
                guard let id = pendingScrollID else { return }
                pendingScrollID = nil
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(id, anchor: .top)
                }
            }
            // A fragment can arrive while this reading already stands
            // open — the camera finding a page of this document, say —
            // not only on appearance.
            .onChange(of: state.pendingFragment) {
                guard let fragment = state.pendingFragment else { return }
                land(fragment, with: proxy)
            }
            .onAppear { landOnArrival(proxy) }
        }
        // KS: Author's foot — the mode words at the bottom of the
        // page, Scroll | Horizontal, the contents and the type at the
        // trailing edge.
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        // The theme's page behind everything.
        .background(AppGreys.page.ignoresSafeArea())
        // Where this window is: full screen or not, and on which kind
        // of display — the full-screen measure follows.
        .background {
            ReaderWindowWatcher { state in
                windowState = state
            }
        }
        // KS: ⌘−/⌘+ fold and unfold through the View menu; ⌘⇧± and
        // ⌥⌘± set the type the same way. The menu asks the focused
        // scene, so the front reading answers.
        .focusedSceneValue(\.outlineFold, OutlineFoldActions(
            folded: foldLevel > 0,
            fold: { fold(by: 1) },
            unfold: { fold(by: -1) }))
        .focusedSceneValue(\.readingTypography, ReadingTypographyActions(
            bigger: { stepFontSize(by: 1) },
            smaller: { stepFontSize(by: -1) },
            looser: { stepLineSpacing(by: 1) },
            tighter: { stepLineSpacing(by: -1) }))
        // The front book announces itself printable — File ▸ Print
        // Booklet… acts on it while this reading is front.
        .focusedSceneValue(\.bookletSource, state.epubCompanionURL(for: doc))
        .onChange(of: expandParagraphs) { _, on in
            if on { computeParagraphSplits() }
        }
        .onChange(of: boldKeySentences) { _, on in
            if on { computeKeySentences() }
        }
        // The moment's notice, briefly.
        .overlay(alignment: .bottom) {
            if let keepNotice {
                Text(keepNotice)
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Tab toggles the glossary overview — grey text, Marked terms,
        // definitions a click away — unless something is being edited.
        .onAppear {
            tabMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 48,   // Tab
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                      let window = NSApp.keyWindow,
                      window.windowNumber == windowState.windowNumber,
                      window.attachedSheet == nil
                else { return event }
                if let editor = window.firstResponder as? NSTextView, editor.isEditable {
                    return event
                }
                withAnimation(.easeInOut(duration: 0.15)) {
                    glossaryOverviewOn.toggle()
                }
                return nil
            }
            // Bare p, f, and b — the reading functions — and Esc,
            // Author's door in and out of full screen. The selectable text views
            // consume unmodified keys before the menu bar sees them, so
            // the window listens directly; anything editable keeps its
            // letters, and an open popover keeps its own Esc.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                      let window = NSApp.keyWindow,
                      window.windowNumber == windowState.windowNumber,
                      window.attachedSheet == nil
                else { return event }
                if let editor = window.firstResponder as? NSTextView, editor.isEditable {
                    return event
                }
                if event.keyCode == 53 {   // Esc
                    window.toggleFullScreen(nil)
                    return nil
                }
                guard let letter = event.charactersIgnoringModifiers?.lowercased(),
                      letter == "p" || letter == "f" || letter == "b"
                else { return event }
                if letter == "p" {
                    expandParagraphs.toggle()
                } else if letter == "b" {
                    boldKeySentences.toggle()
                } else {
                    flowReading.toggle()
                }
                return nil
            }
            // Pinch on the trackpad folds and unfolds — in is ⌘−,
            // out is ⌘+ — one step per gesture's worth of travel.
            pinchMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { event in
                guard event.window?.windowNumber == windowState.windowNumber else {
                    return event
                }
                if event.phase == .began { pinchAccumulator = 0 }
                pinchAccumulator += event.magnification
                if pinchAccumulator <= -0.3 {
                    fold(by: 1)
                    pinchAccumulator = 0
                } else if pinchAccumulator >= 0.3 {
                    fold(by: -1)
                    pinchAccumulator = 0
                }
                return nil
            }
            // KS: two-finger swipes turn the pages in Horizontal when
            // more than two columns stand across — a clearly sideways
            // movement only, one turn per gesture; the columns keep
            // their own vertical scroll, and momentum never re-turns.
            swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                guard event.window?.windowNumber == windowState.windowNumber,
                      readerMode == .horizontal, foldLevel == 0,
                      event.hasPreciseScrollingDeltas else { return event }
                let shown = horizontalPageCount(width: horizontalViewWidth,
                                                sections: horizontalPages.count)
                guard shown > 2 else { return event }
                if event.phase == .began {
                    swipeAccumulatorX = 0
                    swipeTurned = false
                }
                guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
                else { return event }
                if event.momentumPhase != [] { return nil }
                swipeAccumulatorX += event.scrollingDeltaX
                if !swipeTurned, abs(swipeAccumulatorX) > 60 {
                    swipeTurned = true
                    // Natural scrolling: fingers left brings the pages
                    // to the right — the next spread.
                    turnPages(by: swipeAccumulatorX < 0 ? shown : -shown)
                }
                if event.phase == .ended || event.phase == .cancelled {
                    swipeAccumulatorX = 0
                    swipeTurned = false
                }
                return nil
            }
        }
        .onDisappear {
            if let tabMonitor { NSEvent.removeMonitor(tabMonitor) }
            tabMonitor = nil
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            if let pinchMonitor { NSEvent.removeMonitor(pinchMonitor) }
            pinchMonitor = nil
            if let swipeMonitor { NSEvent.removeMonitor(swipeMonitor) }
            swipeMonitor = nil
        }
        .sheet(item: $commentTarget) { target in
            CommentComposer(preview: target.preview) { text in
                state.addComment(text, to: doc, paragraphID: target.paragraphID)
            }
        }
        .sheet(item: $conceptTarget) { concept in
            ConceptSheet(concept: concept)
        }
        .sheet(item: $citationTarget) { target in
            CitationCardSheet(doc: doc, key: target.key)
        }
        .sheet(item: $noteTarget) { target in
            EndnoteSheet(text: OrigamiReading.endnote(withID: target.noteID, in: doc)
                .map { rendered($0.text) }
                ?? AttributedString("The document carries no note \(target.noteID)."))
        }
        .sheet(isPresented: $showReferences) {
            ReferencesSheet(doc: doc)
        }
        // A tapped citation opens the source's card; a fold-to-concepts
        // term opens its definition; every other link opens as links do.
        .environment(\.openURL, OpenURLAction { url in
            if let key = OrigamiReading.citationKey(from: url) {
                if openSourcesIn != "ask",
                   state.autoOpenCitation(key: key, in: doc, preferred: openSourcesIn) {
                    return .handled
                }
                citationTarget = CitationTarget(key: key)
                return .handled
            }
            if url.scheme == "origami-conceptcard" {
                let id = String(url.absoluteString.dropFirst("origami-conceptcard:".count))
                if let concept = doc.concepts.first(where: { $0.id == id }) {
                    conceptTarget = concept
                }
                return .handled
            }
            return .systemAction
        })
        .navigationTitle(doc.title)
    }

    // MARK: - KS: arriving and remembering

    /// Land where the reading asks: a fragment link's paragraph first;
    /// otherwise, in the article flow, where the reader left off.
    private func landOnArrival(_ proxy: ScrollViewProxy) {
        if let fragment = state.pendingFragment, land(fragment, with: proxy) {
            return
        }
        if readerMode == .scroll, foldLevel == 0 {
            let saved = UserDefaults.standard.double(forKey: progressKey)
            guard saved > 0 else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                scrollPosition.scrollTo(y: saved)
            }
        }
    }

    /// An arriving fragment, landed — but only a fragment of THIS
    /// document; another reading's fragment is left for its own
    /// window to consume. Scroll flows to the paragraph; Horizontal
    /// and Focus turn to its page first.
    @discardableResult
    private func land(_ fragment: String, with proxy: ScrollViewProxy) -> Bool {
        let mine = (doc.body ?? []).contains { $0.id == fragment }
            || sections.contains { $0.heading?.id == fragment }
        guard mine else { return false }
        state.pendingFragment = nil
        if readerMode == .horizontal || readerMode == .focus {
            if let page = horizontalPages.firstIndex(where: { page in
                page.contains { section in
                    section.heading?.id == fragment
                        || section.paragraphs.contains { $0.id == fragment }
                }
            }) {
                withAnimation(.easeInOut(duration: 0.2)) { focusIndex = page }
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(fragment, anchor: .top)
            }
        }
        return true
    }

    private var progressKey: String { "readingProgress.\(doc.id)" }

    /// The scroll offset, saved a moment after each move.
    private func noteProgress(_ offset: CGFloat) {
        progressSaveTask?.cancel()
        let key = progressKey
        progressSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            UserDefaults.standard.set(Double(max(offset, 0)), forKey: key)
        }
    }

    // MARK: - KS: the foot

    /// Author's foot, carried across: the mode words at the bottom of
    /// the page — Scroll | Horizontal | Focus — with the contents, the
    /// fold, and the type standing quietly at the trailing edge.
    private var bottomBar: some View {
        ZStack {
            HStack(spacing: 18) {
                modeWord("Scroll", mode: .scroll)
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 1, height: 14)
                modeWord("Horizontal", mode: .horizontal)
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 1, height: 14)
                modeWord("Focus", mode: .focus)
            }
            HStack(spacing: 14) {
                if foldLevel > 0 {
                    Text("Folded — level \(foldLevel)")
                        .font(.caption)
                        .foregroundStyle(AppGreys.quietText)
                }
                Spacer()
                Button {
                    showContents = true
                } label: {
                    Image(systemName: "list.bullet")
                        .foregroundStyle(AppGreys.quietText)
                }
                .buttonStyle(.plain)
                .disabled(sections.isEmpty)
                .help("Contents — every section, one click away")
                .popover(isPresented: $showContents) { contentsList }

                Menu {
                    Button("Fold (⌘−)") { fold(by: 1) }
                        .disabled(foldLevel >= OrigamiReading.maxFoldLevel(of: doc))
                    Button("Unfold (⌘+)") { fold(by: -1) }
                        .disabled(foldLevel == 0)
                    Divider()
                    Picker("Fold to", selection: $foldTargetRaw) {
                        ForEach(FoldTarget.allCases) { target in
                            Text(target.displayName).tag(target.rawValue)
                        }
                    }
                } label: {
                    Image(systemName: "rectangle.compress.vertical")
                        .foregroundStyle(AppGreys.quietText)
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .fixedSize()
                .help("Fold the document to its structure — headings, concepts, or names")

                Menu {
                    typeMenu
                } label: {
                    Text("Aa")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(AppGreys.quietText)
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .fixedSize()
                .help("The reading's type: size, spacing, measure, marks, glossary, colour")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(AppGreys.page)
        .overlay(alignment: .top) { Divider() }
    }

    /// One mode word at the foot, Author's way: the chosen one in the
    /// heading ink, the other resting quiet.
    private func modeWord(_ label: String, mode: ReaderMode) -> some View {
        Button {
            withAnimation(.snappy) { readerModeRaw = mode.rawValue }
        } label: {
            Text(label)
                .font(.callout.weight(readerMode == mode ? .semibold : .regular))
                .foregroundStyle(readerMode == mode ? AppGreys.heading : AppGreys.quietText)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(mode == .scroll ? "The document as written, one flow"
              : mode == .horizontal
                ? "Pages side by side — two, or more when the window is wide"
                : "One section alone, to settle into — arrows move through")
    }

    /// KS: the contents — the document by its headings, each a click.
    private var contentsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(sections) { section in
                    Button {
                        showContents = false
                        jump(to: section)
                    } label: {
                        Text(section.title)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .padding(.leading, CGFloat(max(section.level - 1, 0)) * 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .frame(width: 340, height: min(CGFloat(sections.count) * 30 + 40, 460))
    }

    /// KS: the Aa menu — every way the type is set. A loaded LaTeX
    /// style leads it, one flick between the style's dress and the
    /// reader's own.
    @ViewBuilder private var typeMenu: some View {
        if let profile = LaTeXStyleProfile.decode(latexRaw) {
            Toggle("LaTeX Style — \(profile.name)", isOn: $latexOn)
        }
        Section("Text Size") {
            Button("Bigger (⇧⌘+)") { stepFontSize(by: 1) }
            Button("Smaller (⇧⌘−)") { stepFontSize(by: -1) }
        }
        Section("Line Spacing") {
            Button("Looser (⌥⌘+)") { stepLineSpacing(by: 1) }
            Button("Tighter (⌥⌘−)") { stepLineSpacing(by: -1) }
        }
        Section("Measure") {
            if windowState.isFullScreen {
                Button("Wider") { stepFullScreenMeasure(by: 4) }
                Button("Narrower") { stepFullScreenMeasure(by: -4) }
            } else {
                Button("Wider") { windowedMeasure = min(windowedMeasure + 40, 1200) }
                Button("Narrower") { windowedMeasure = max(windowedMeasure - 40, 380) }
            }
        }
        Picker("Marked Text", selection: $markedStyleRaw) {
            ForEach(MarkedTextStyle.allCases) { style in
                Text(style.displayName).tag(style.rawValue)
            }
        }
        Picker("Glossary", selection: $glossaryDisplayRaw) {
            ForEach(GlossaryDisplay.allCases) { display in
                Text(display.displayName).tag(display.rawValue)
            }
        }
        Picker("Colour Words By", selection: $coloringModeRaw) {
            ForEach(TextColoringMode.allCases) { mode in
                Text(mode.displayName).tag(mode.rawValue)
            }
        }
        Picker("Stretchtext", selection: $stretchDisplayRaw) {
            ForEach(StretchtextDisplay.allCases) { display in
                Text(display.displayName).tag(display.rawValue)
            }
        }
    }

    /// KS: one section into view, whichever mode is reading.
    private func jump(to section: OrigamiSection) {
        if let index = sections.firstIndex(of: section) {
            steppedIndex = index
        }
        if readerMode == .horizontal || readerMode == .focus {
            if let page = horizontalPages.firstIndex(where: { $0.contains(section) }) {
                focusIndex = page
            }
            return
        }
        // Folded or flowing: land on the section's first paragraph.
        if let target = section.heading?.id ?? section.paragraphs.first?.id {
            pendingScrollID = target
        }
    }

    private func stepFullScreenMeasure(by delta: Double) {
        if windowState.isBuiltInDisplay {
            fullScreenWidthInternal = min(max(fullScreenWidthInternal + delta, 25), 100)
        } else {
            fullScreenWidthExternal = min(max(fullScreenWidthExternal + delta, 25), 100)
        }
    }

    // MARK: - The styles

    /// The classic flow: everything in order, one measure — and, KS,
    /// the scroll remembered per document.
    private func articleView(_ annotations: [String: [ResolvedAnnotation]]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: flowSpacing) {
                header
                Divider()
                flow(doc.body ?? [], annotations: annotations)
            }
            .padding(32)
            .frame(maxWidth: measure, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y
        } action: { _, offset in
            noteProgress(offset)
        }
    }

    /// The document folded to the current level: headings with their
    /// first sentences and Marked lines, or fewer — the same measure
    /// as the article. A click on any heading opens every section and
    /// the view stays on the heading clicked; a second click folds
    /// them again. A ctrl- or right-click is the reading menu —
    /// extraction included — never a fold.
    private func foldedView(_ paragraphs: [LiquidDoc.Paragraph],
                            annotations: [String: [ResolvedAnnotation]]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: flowSpacing) {
                header
                Divider()
                ForEach(foldedSegments(paragraphs)) { segment in
                    switch segment {
                    case .heading(let paragraph):
                        Text(rendered(paragraph.text))
                            .font(paragraphFont(paragraph))
                            .foregroundStyle(themeHeading.map(AnyShapeStyle.init)
                                             ?? AnyShapeStyle(.primary))
                            .contentShape(Rectangle())
                            .contextMenu {
                                menuView(menuEntries(for: paragraph, highlights: []))
                            }
                            .onTapGesture { toggleFoldSection(paragraph.id) }
                            .help(expandedFold.isEmpty
                                  ? "Open all sections" : "Fold all sections")
                            .id(paragraph.id)
                        // KS: the alternate fold targets — under each
                        // heading, the section's Defined Concepts or
                        // the people it names, each a click to its card.
                        if foldTarget != .headings, expandedFold.isEmpty {
                            termsLine(under: paragraph)
                        }
                    case .run(let run):
                        flow(run, annotations: annotations)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: measure, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    /// KS: the terms a section mentions, as quiet clickable words under
    /// its folded heading — Author's fold-to-glossary and fold-to-names.
    @ViewBuilder
    private func termsLine(under heading: LiquidDoc.Paragraph) -> some View {
        let terms = sectionTerms(under: heading)
        if !terms.isEmpty {
            Text(termsAttributed(terms))
                .font(.callout)
                .padding(.leading, 4)
        }
    }

    private func sectionTerms(under heading: LiquidDoc.Paragraph) -> [LiquidDoc.Concept] {
        guard let section = sections.first(where: { $0.heading?.id == heading.id })
        else { return [] }
        var seen = Set<String>()
        var terms: [LiquidDoc.Concept] = []
        for paragraph in section.paragraphs {
            for concept in OrigamiReading.concepts(in: paragraph, of: doc) {
                let isPerson = concept.tag?.caseInsensitiveCompare("person") == .orderedSame
                guard foldTarget == .names ? isPerson : !isPerson else { continue }
                if seen.insert(concept.id).inserted { terms.append(concept) }
            }
        }
        return terms
    }

    private func termsAttributed(_ terms: [LiquidDoc.Concept]) -> AttributedString {
        var out = AttributedString()
        for (index, concept) in terms.enumerated() {
            if index > 0 {
                var dot = AttributedString("  ·  ")
                dot.foregroundColor = themeDimmed
                out += dot
            }
            var term = AttributedString(concept.name)
            term.foregroundColor = themeDimmed
            term.link = URL(string: "origami-conceptcard:" + concept.id)
            out += term
        }
        return out
    }

    /// The folded list split for rendering: each heading stands alone
    /// (clickable), the paragraphs between flow with their stretch
    /// blocks intact.
    private enum FoldedSegment: Identifiable {
        case heading(LiquidDoc.Paragraph)
        case run([LiquidDoc.Paragraph])

        var id: String {
            switch self {
            case .heading(let paragraph): paragraph.id
            case .run(let run): "run-" + (run.first?.id ?? "empty")
            }
        }
    }

    private func foldedSegments(_ paragraphs: [LiquidDoc.Paragraph]) -> [FoldedSegment] {
        var segments: [FoldedSegment] = []
        var run: [LiquidDoc.Paragraph] = []
        for paragraph in paragraphs {
            if paragraph.heading != nil {
                if !run.isEmpty { segments.append(.run(run)); run = [] }
                segments.append(.heading(paragraph))
            } else {
                run.append(paragraph)
            }
        }
        if !run.isEmpty { segments.append(.run(run)) }
        return segments
    }

    /// A click on any folded heading opens every section — the whole
    /// document unfolds in place; a second click folds them all again.
    /// Either way the view settles on the heading that was clicked,
    /// since everything above it just changed size.
    private func toggleFoldSection(_ headingID: String) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if expandedFold.isEmpty {
                expandedFold = Set((doc.body ?? []).compactMap {
                    $0.heading != nil ? $0.id : nil
                })
            } else {
                expandedFold = []
            }
        }
        // Land after the new layout is in.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            pendingScrollID = headingID
        }
    }

    /// One fold step in either direction, clamped to the document's
    /// ladder — 0 is fully open. Stepping resets the opened sections.
    private func fold(by delta: Int) {
        withAnimation(.easeInOut(duration: 0.15)) {
            foldLevel = min(max(foldLevel + delta, 0), OrigamiReading.maxFoldLevel(of: doc))
            expandedFold = []
        }
    }

    /// A paragraph run with its stretch blocks folded. The `»` toggle
    /// rides inline at the end of the paragraph the stretch follows —
    /// where Author writes it — and the opened detail reads as a
    /// callout or inline.
    @ViewBuilder
    private func flow(_ paragraphs: [LiquidDoc.Paragraph],
                      annotations: [String: [ResolvedAnnotation]]) -> some View {
        let items = OrigamiFlowItem.build(paragraphs)
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            switch item {
            case .paragraph(let paragraph):
                let trailing: (id: String, run: [LiquidDoc.Paragraph])? = {
                    guard isPlainText(paragraph), index + 1 < items.count,
                          case .stretch(let id, let run) = items[index + 1]
                    else { return nil }
                    return (id, run)
                }()
                paragraphView(paragraph, annotations: annotations[paragraph.id] ?? [],
                              trailingStretch: trailing)
                    .id(paragraph.id)   // KS: the contents and fragments land here
            case .stretch(let id, let run):
                let hosted: Bool = {
                    guard index > 0, case .paragraph(let host) = items[index - 1]
                    else { return false }
                    return isPlainText(host)
                }()
                stretchBlock(id: id, run: run, annotations: annotations, hosted: hosted)
            }
        }
    }

    /// Whether a paragraph is running text — something an inline
    /// stretch toggle can end. Images, tables, and rules are not.
    private func isPlainText(_ paragraph: LiquidDoc.Paragraph) -> Bool {
        paragraph.tableID == nil && paragraph.text != "---"
            && LiquidDoc.imageReference(in: paragraph.text) == nil
    }

    /// One stretchtext block's detail. Its toggle lives inline in the
    /// host paragraph; only a stretch with no text before it (rare)
    /// gets a toggle of its own here.
    @ViewBuilder
    private func stretchBlock(id: String, run: [LiquidDoc.Paragraph],
                              annotations: [String: [ResolvedAnnotation]],
                              hosted: Bool) -> some View {
        let isOpen = openStretch.contains(id)
        if !hosted {
            Button {
                toggleStretch(id)
            } label: {
                Text(isOpen ? "\u{2039}" : "\u{00BB}")
                    .font(.callout.bold())
                    .foregroundStyle(themeText.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
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
                    paragraphView(paragraph, annotations: annotations[paragraph.id] ?? [],
                                  closeStretch: (id, paragraph.id == run.last?.id))
                }
            }
            switch stretchDisplay {
            case .callout:
                content
                    .padding(.leading, 14)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(.tertiary)
                            .frame(width: 3)
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

    /// The document by its structure: sections fold under their headings.
    private func outlineView(_ annotations: [String: [ResolvedAnnotation]]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                Divider()
                ForEach(sections) { section in
                    if let heading = section.heading {
                        DisclosureGroup(isExpanded: expansion(of: section)) {
                            VStack(alignment: .leading, spacing: 14) {
                                flow(section.paragraphs, annotations: annotations)
                            }
                            .padding(.top, 8)
                        } label: {
                            Text(rendered(heading.text))
                                .font(headingFont(level: section.level))
                                .foregroundStyle(themeHeading.map(AnyShapeStyle.init)
                                                 ?? AnyShapeStyle(.primary))
                                .greyedOut(selectionMode != nil) { selectionMode = nil }
                                .dimmedForStretch(stretchFocus)
                        }
                        .id(heading.id)
                    } else {
                        flow(section.paragraphs, annotations: annotations)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: measure, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    /// KS: Horizontal — the document as pages side by side: a spread
    /// of two at least, a page more for every 460 points the window
    /// offers. Previous/Next (and the arrow keys) turn by a whole
    /// spread; sections are the pages, each scrolling within itself.
    private func horizontalView(_ annotations: [String: [ResolvedAnnotation]]) -> some View {
        let pages = horizontalPages
        let shown = horizontalPageCount(width: horizontalViewWidth,
                                        sections: pages.count)
        let index = min(max(focusIndex, 0), max(pages.count - 1, 0))
        return VStack(spacing: 0) {
            if pages.isEmpty {
                ContentUnavailableView("Nothing to Read", systemImage: "doc.text",
                                       description: Text("This document has no body."))
            } else {
                HStack(spacing: 0) {
                    ForEach(0..<shown, id: \.self) { offset in
                        Group {
                            if index + offset < pages.count {
                                focusColumn(pages[index + offset],
                                            annotations: annotations)
                            } else {
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                        if offset < shown - 1 { Divider() }
                    }
                }
                Divider()
                HStack {
                    Button {
                        turnPages(by: -shown)
                    } label: {
                        Label("Previous", systemImage: "chevron.left")
                    }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(index == 0)

                    Spacer()
                    Text(pageLabel(pages: pages, index: index, shown: shown))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()

                    Button {
                        turnPages(by: shown)
                    } label: {
                        Label("Next", systemImage: "chevron.right")
                    }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(index + shown >= pages.count)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
        }
        // The page count follows the reading area's width.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            horizontalViewWidth = width
        }
    }

    /// KS: Focus — one section alone on the page, to help the reading
    /// settle. Previous/Next (and the arrow keys) move a section at a
    /// time; the section scrolls within itself. The pages are
    /// Horizontal's, so bodyless headings ride atop their section and
    /// the two modes keep each other's place.
    private func focusView(_ annotations: [String: [ResolvedAnnotation]]) -> some View {
        let pages = horizontalPages
        let index = min(max(focusIndex, 0), max(pages.count - 1, 0))
        return VStack(spacing: 0) {
            if pages.isEmpty {
                ContentUnavailableView("Nothing to Read", systemImage: "doc.text",
                                       description: Text("This document has no body."))
            } else {
                focusColumn(pages[index], annotations: annotations)
                Divider()
                HStack {
                    Button {
                        turnPages(by: -1)
                    } label: {
                        Label("Previous", systemImage: "chevron.left")
                    }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(index == 0)

                    Spacer()
                    Text(pageLabel(pages: pages, index: index, shown: 1))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()

                    Button {
                        turnPages(by: 1)
                    } label: {
                        Label("Next", systemImage: "chevron.right")
                    }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(index >= pages.count - 1)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
        }
    }

    /// KS: the Horizontal pages — one section each, except that a
    /// heading with no body of its own (a part over its chapters, a
    /// heading straight into the next) never breaks to a page alone:
    /// it rides atop the section that follows.
    private var horizontalPages: [[OrigamiSection]] {
        var pages: [[OrigamiSection]] = []
        var pending: [OrigamiSection] = []
        for section in sections {
            if hasBody(section) {
                pages.append(pending + [section])
                pending = []
            } else {
                pending.append(section)
            }
        }
        if !pending.isEmpty {
            // Bare headings at the very end stay with the last page.
            if pages.isEmpty {
                pages.append(pending)
            } else {
                pages[pages.count - 1] += pending
            }
        }
        return pages
    }

    /// A section with something of its own to read — words, a figure,
    /// a table.
    private func hasBody(_ section: OrigamiSection) -> Bool {
        section.paragraphs.contains { paragraph in
            paragraph.tableID != nil
                || LiquidDoc.imageReference(in: paragraph.text) != nil
                || !paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Pages across the width: two at least, a page more for every 460
    /// points, never more pages than sections.
    private func horizontalPageCount(width: CGFloat, sections: Int) -> Int {
        guard sections > 0 else { return 1 }
        guard width > 0 else { return min(2, sections) }
        return min(max(Int(width / 460), 2), sections)
    }

    /// One whole spread forward or back, clamped to the document.
    private func turnPages(by delta: Int) {
        let count = horizontalPages.count
        guard count > 0 else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            focusIndex = min(max(focusIndex + delta, 0), count - 1)
        }
    }

    /// "Introduction — 3–5 of 12": the spread's place in the whole.
    private func pageLabel(pages: [[OrigamiSection]], index: Int, shown: Int) -> String {
        let count = pages.count
        let last = min(index + shown, count)
        let title = pages[index].first(where: hasBody)?.title
            ?? pages[index].first?.title ?? ""
        if last - index <= 1 {
            return "\(title) — \(index + 1) of \(count)"
        }
        return "\(title) — \(index + 1)–\(last) of \(count)"
    }

    /// One Horizontal page: its section — with any bodyless headings
    /// that ride above it, stacked without a break.
    private func focusColumn(_ page: [OrigamiSection],
                             annotations: [String: [ResolvedAnnotation]]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: latex == nil ? 20 : flowSpacing) {
                ForEach(page) { section in
                    if let heading = section.heading {
                        Text(rendered(heading.text))
                            .font(headingFont(level: section.level))
                            .foregroundStyle(themeHeading.map(AnyShapeStyle.init)
                                             ?? AnyShapeStyle(.primary))
                            .greyedOut(selectionMode != nil) { selectionMode = nil }
                            .dimmedForStretch(stretchFocus)
                            .id(heading.id)
                    }
                    flow(section.paragraphs, annotations: annotations)
                }
            }
            .padding(40)
            .frame(maxWidth: windowState.isFullScreen ? measure : 560,
                   alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    /// Speaker-labelled turns; a document without speakers reads as flow.
    private func transcriptView(_ annotations: [String: [ResolvedAnnotation]]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider()
                ForEach(turns) { turn in
                    VStack(alignment: .leading, spacing: 8) {
                        if let speaker = turn.speaker {
                            Text(speaker)
                                .font(.headline)
                                .foregroundStyle(.tint)
                        }
                        flow(turn.paragraphs, annotations: annotations)
                    }
                    .padding(.leading, turn.speaker == nil ? 0 : 12)
                    .overlay(alignment: .leading) {
                        if turn.speaker != nil {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(.tertiary)
                                .frame(width: 3)
                        }
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: measure, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    /// Consecutive paragraphs by the same speaker, one turn.
    private struct Turn: Identifiable {
        let speaker: String?
        let paragraphs: [LiquidDoc.Paragraph]
        var id: String { paragraphs.first?.id ?? "turn" }
    }

    private var turns: [Turn] {
        var turns: [Turn] = []
        var speaker: String?
        var run: [LiquidDoc.Paragraph] = []
        for paragraph in doc.body ?? [] {
            if paragraph.speaker != speaker, !run.isEmpty {
                turns.append(Turn(speaker: speaker, paragraphs: run))
                run = []
            }
            speaker = paragraph.speaker
            run.append(paragraph)
        }
        if !run.isEmpty { turns.append(Turn(speaker: speaker, paragraphs: run)) }
        return turns
    }

    // MARK: - Header and shared pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            // KS: a book opens on its cover, when the EPUB carried one.
            if let cover = coverImage {
                Image(nsImage: cover)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(radius: 3, y: 1)
                    .padding(.bottom, 12)
            }
            Text(doc.title)
                .font(Font.custom(headingFontName,
                                  size: max(NSFont.preferredFont(forTextStyle: .largeTitle).pointSize
                                            + fontDelta - 1, 8)))
                .foregroundStyle(themeHeading.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
            Text("\(doc.displayAuthor) · \(doc.listedDateText)")
                .font(.headline)
                .foregroundStyle(themeDimmed.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
            // An excerpt says where it came from — and, when the
            // library holds the original, the line is the way back,
            // opened at the very section.
            if let excerpt = doc.excerptOf {
                Button {
                    openOriginal(excerpt)
                } label: {
                    Label {
                        Text("An excerpt of \u{201C}\(excerpt.title)\u{201D} (\(excerpt.author))")
                    } icon: {
                        Image(systemName: "rectangle.portrait.on.rectangle.portrait")
                    }
                    .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .help("Open the original document at this section")
            }
            HStack(spacing: 12) {
                if sections.count > 1 {
                    Label("\(sections.count) sections", systemImage: "list.bullet.indent")
                }
                if !doc.references.isEmpty {
                    Label("\(doc.references.count) references",
                          systemImage: "list.bullet.rectangle")
                }
                if !doc.concepts.isEmpty {
                    Label("\(doc.concepts.count) concepts", systemImage: "lightbulb")
                }
            }
            .font(.caption)
            .foregroundStyle(themeDimmed.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
        }
        .greyedOut(selectionMode != nil) { selectionMode = nil }
        .dimmedForStretch(stretchFocus)
    }

    /// KS: the EPUB's cover, when the import carried one — an asset
    /// whose id, file name, or alt says "cover".
    private var coverImage: NSImage? {
        let asset = doc.assets.first { asset in
            asset.id.localizedCaseInsensitiveContains("cover")
                || asset.filename.localizedCaseInsensitiveContains("cover")
                || asset.alt?.localizedCaseInsensitiveContains("cover") == true
        }
        return asset?.data.flatMap(NSImage.init(data:))
    }

    /// KS: the excerpt's original, opened in the library at its section.
    private func openOriginal(_ excerpt: LiquidDoc.ExcerptOf) {
        if let entry = state.index.allByID[excerpt.id] {
            state.openInLibrary(entry.doc, fragment: excerpt.headingID)
        } else {
            flashNotice("The original document isn\u{2019}t in the library.")
        }
    }

    private func headingFont(level: Int) -> Font {
        let font = Font.custom(headingFontName, size: headingPointSize(level: level))
        return latex != nil ? font.weight(.bold) : font
    }

    private func expansion(of section: OrigamiSection) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(section.id) },
                set: { open in
                    if open { collapsed.remove(section.id) }
                    else { collapsed.insert(section.id) }
                })
    }

    /// What the reader has done to the view right now — the style, the
    /// outline sections folded closed, the stretchtext opened, the
    /// focused section. Copied citations carry this.
    private var viewState: OrigamiViewState {
        let sections = self.sections
        var focusSectionID: String?
        let pages = horizontalPages
        if readerMode != .scroll, !pages.isEmpty {
            let index = min(max(focusIndex, 0), pages.count - 1)
            focusSectionID = pages[index].first?.heading?.id
        }
        return OrigamiViewState(
            style: readerMode != .scroll ? .focus : .article,
            closedSections: [],
            openStretch: openStretch.sorted(),
            focusSectionID: focusSectionID)
    }

    /// Every annotation on the document, re-anchored through the selector
    /// ladder and grouped by the paragraph it lands on.
    private var resolvedByParagraph: [String: [ResolvedAnnotation]] {
        var map: [String: [ResolvedAnnotation]] = [:]
        for annotation in state.annotations(for: doc) {
            guard let resolution = AnnotationAnchor.resolve(annotation, in: doc) else { continue }
            map[resolution.paragraphID, default: []]
                .append(ResolvedAnnotation(annotation: annotation, resolution: resolution))
        }
        return map
    }

    // MARK: - One paragraph

    /// One body element: a heading, a rule, an image from the asset pool, a
    /// table's plain-text fallback, or a text paragraph with its inline
    /// markdown rendered, highlights painted, comments beneath — and the
    /// reader's chosen context menu.
    @ViewBuilder
    private func paragraphView(_ paragraph: LiquidDoc.Paragraph,
                               annotations: [ResolvedAnnotation],
                               trailingStretch: (id: String, run: [LiquidDoc.Paragraph])? = nil,
                               closeStretch: (id: String, isLast: Bool)? = nil)
        -> some View {
        if let mode = selectionMode, mode.paragraphID == paragraph.id {
            SelectionModeView(mode: mode, font: paragraphFont(paragraph)) {
                selectionMode = nil
            }
        } else {
            standardParagraphView(paragraph, annotations: annotations,
                                  trailingStretch: trailingStretch,
                                  closeStretch: closeStretch)
                .greyedOut(selectionMode != nil) { selectionMode = nil }
        }
    }

    @ViewBuilder
    private func standardParagraphView(_ paragraph: LiquidDoc.Paragraph,
                                       annotations: [ResolvedAnnotation],
                                       trailingStretch: (id: String, run: [LiquidDoc.Paragraph])? = nil,
                                       closeStretch: (id: String, isLast: Bool)? = nil)
        -> some View {
        let inlineOpenHost = trailingStretch.map {
            openStretch.contains($0.id) && stretchDisplay == .inline
        } ?? false
        let dim = stretchFocus && closeStretch == nil && !inlineOpenHost
        if let image = LiquidDoc.imageReference(in: paragraph.text),
           let asset = doc.assets.first(where: { $0.id == image.id }) {
            // KS: the notes reader's asset view, not a bare image — an
            // Interatlas figure keeps its embedded citation and answers
            // a click with the way back into Liquid Information.
            VStack(alignment: .leading, spacing: 6) {
                OrigamiAssetView(asset: asset,
                                 fallback: DocumentReaderView.imageCitation(
                                     after: paragraph, in: doc),
                                 doc: doc)
                if !image.alt.isEmpty {
                    Text(image.alt).font(.caption).foregroundStyle(.secondary)
                }
            }
            .dimmedForStretch(dim)
        } else if let tableID = paragraph.tableID,
                  let table = doc.tables.first(where: { $0.identifier == tableID }) {
            // A live table from the document's pool — a clean grid,
            // its header ruled off — never the pipe-text stand-in.
            OrigamiTableView(table: table, doc: doc, paragraphID: paragraph.id)
                .contextMenu {
                    menuView(menuEntries(for: paragraph, highlights: []))
                }
                .dimmedForStretch(dim)
        } else if paragraph.tableID != nil {
            // The pool lost this table: the paragraph's own pipe-text
            // stands in, plainly marked as such.
            Text(paragraph.text)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(themeText.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .contextMenu {
                    menuView(menuEntries(for: paragraph, highlights: []))
                }
                .dimmedForStretch(dim)
        } else if paragraph.text == "---" {
            Divider()
                .dimmedForStretch(dim)
        } else {
            annotatedParagraph(paragraph, annotations: annotations,
                               trailingStretch: trailingStretch,
                               closeStretch: closeStretch,
                               dimmed: dim)
        }
    }

    private func annotatedParagraph(_ paragraph: LiquidDoc.Paragraph,
                                    annotations: [ResolvedAnnotation],
                                    trailingStretch: (id: String, run: [LiquidDoc.Paragraph])? = nil,
                                    closeStretch: (id: String, isLast: Bool)? = nil,
                                    dimmed: Bool = false)
        -> some View {
        let highlights = annotations.filter {
            $0.annotation.motivation == WebAnnotation.Motivation.highlighting
        }
        let comments = annotations.filter { $0.annotation.body != nil }
        let wholeParagraph = highlights.contains { $0.resolution.exact == nil }
        return VStack(alignment: .leading, spacing: 8) {
            // An NSTextView-backed paragraph: text selects normally, but
            // right-click shows exactly the reading menu — none of the
            // items macOS adds to selectable SwiftUI text (Look Up,
            // Translate, Services…).
            SelectableParagraph(
                attributed: inlineText(paragraph, highlights: highlights,
                                       trailingStretch: trailingStretch,
                                       closeStretch: closeStretch),
                baseFont: nsFont(for: paragraph),
                lineSpacing: effectiveLineSpacing(for: paragraph),
                justified: latex != nil,
                firstLineIndent: latex != nil && paragraph.heading == nil
                    ? CGFloat(latex?.parIndent ?? 15) : 0,
                inkColor: inkColor(for: paragraph),
                dimmed: dimmed,
                dimInk: themeDimmed.map(NSColor.init) ?? .secondaryLabelColor,
                entries: menuEntries(for: paragraph, highlights: highlights),
                selectionEntries: selectionEntries(for: paragraph),
                onLink: handleLink)
                .padding(wholeParagraph ? 10 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(wholeParagraph ? Color.yellow.opacity(0.14) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
            ForEach(comments) { entry in
                CommentBubble(entry: entry) {
                    state.removeAnnotation(entry.annotation, for: doc)
                }
            }
        }
    }

    /// The reading context menu as data — exactly the verbs (and order)
    /// of the reader's chosen set, verbs with nothing to say here
    /// staying out. The selectable paragraph builds its NSMenu from
    /// these, the table fallback a SwiftUI menu; one source, no system
    /// items either way.
    private func menuEntries(for paragraph: LiquidDoc.Paragraph,
                             highlights: [ResolvedAnnotation]) -> [ParagraphMenuEntry] {
        var entries: [ParagraphMenuEntry] = []
        for action in enabledActions {
            switch action {
            case .copyText:
                entries.append(.action(title: "Copy Text", symbol: "doc.on.doc") {
                    copy(paragraph.text)
                })
            case .copyCitation:
                entries.append(.action(title: "Copy as Citation", symbol: "quote.opening") {
                    // The citation carries the state of the view — the
                    // style, folded sections, opened stretchtext — both
                    // readably and on the address. Alongside the text
                    // rides Author's own citation payload, so pasting
                    // there makes a full citation.
                    copyCitation(for: paragraph)
                })
            case .copyViewSpec:
                entries.append(.action(title: "Copy View Specification",
                                       symbol: "viewfinder.rectangular") {
                    copy(OrigamiReading.viewSpecification(
                        for: paragraph, in: doc, view: viewState,
                        generator: "Knowledge Space (macOS)").clipboardText())
                })
            case .highlight:
                entries.append(.action(title: "Highlight", symbol: "highlighter") {
                    state.addHighlight(to: doc, paragraphID: paragraph.id)
                })
                if !highlights.isEmpty {
                    entries.append(.action(title: "Remove Highlight", symbol: "eraser") {
                        for entry in highlights {
                            state.removeAnnotation(entry.annotation, for: doc)
                        }
                    })
                }
            case .comment:
                entries.append(.action(title: "Comment…", symbol: "text.bubble") {
                    commentTarget = CommentTarget(paragraphID: paragraph.id,
                                                  preview: paragraph.text)
                })
            case .concepts:
                let matched = OrigamiReading.concepts(in: paragraph, of: doc)
                if !matched.isEmpty {
                    entries.append(.submenu(title: "Concepts Here", symbol: "lightbulb",
                                            items: matched.map { concept in
                                                (concept.name, { conceptTarget = concept })
                                            }))
                }
            case .references:
                if !doc.references.isEmpty {
                    entries.append(.action(title: "Show References (\(doc.references.count))",
                                           symbol: "list.bullet.rectangle") {
                        showReferences = true
                    })
                }
            case .provenance:
                if let provenance = paragraph.provenance, !provenance.isEmpty {
                    entries.append(.action(title: "Copy Provenance", symbol: "signature") {
                        copy(provenance)
                    })
                }
            }
        }
        // A heading can leave with its section: everything under it,
        // to a document of its own that still cites the original —
        // KS: the EPUB Library's own excerptSection.
        if paragraph.heading != nil {
            if !entries.isEmpty { entries.append(.separator) }
            entries.append(.action(title: "Extract Section\u{2026}",
                                   symbol: "rectangle.portrait.and.arrow.right") {
                state.excerptSection(of: doc, headingID: paragraph.id)
            })
        }
        return entries
    }

    /// The entries as SwiftUI menu items, for the table fallback's
    /// contextMenu.
    @ViewBuilder
    private func menuView(_ entries: [ParagraphMenuEntry]) -> some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            switch entry {
            case .action(let title, let symbol, let run):
                Button(title, systemImage: symbol, action: run)
            case .submenu(let title, let symbol, let items):
                Menu(title, systemImage: symbol) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        Button(item.0, action: item.1)
                    }
                }
            case .separator:
                Divider()
            }
        }
    }

    /// The verbs offered over a live selection: highlight exactly these
    /// words (KS), the Flow view, and the AI submenu with the reader's
    /// prompts. The captured prefix/selection/suffix drive the
    /// selection view mode.
    private func selectionEntries(for paragraph: LiquidDoc.Paragraph)
        -> (String, NSRange) -> [ParagraphMenuEntry] {
        { fullText, range in
            guard range.length > 0,
                  let swiftRange = Range(range, in: fullText) else { return [] }
            let prefix = String(fullText[..<swiftRange.lowerBound])
            let selected = String(fullText[swiftRange])
            let suffix = String(fullText[swiftRange.upperBound...])
            guard !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return [] }

            var entries: [ParagraphMenuEntry] = [.separator]
            entries.append(.action(title: "Highlight Selection", symbol: "highlighter") {
                state.addHighlight(to: doc, paragraphID: paragraph.id, exact: selected)
            })
            entries.append(.action(title: "Flow", symbol: "text.line.first.and.arrowtriangle.forward") {
                selectionMode = SelectionViewMode(
                    paragraphID: paragraph.id, prefix: prefix,
                    selected: selected, suffix: suffix, display: .flow)
            })
            let presets = AIPromptPreset.decodeList(aiPromptsRaw)
            if !presets.isEmpty {
                entries.append(.submenu(
                    title: "AI", symbol: "sparkles",
                    items: presets.map { preset in
                        (preset.name, {
                            runAI(preset, paragraphID: paragraph.id,
                                  prefix: prefix, selected: selected, suffix: suffix)
                        })
                    }))
            }
            return entries
        }
    }

    /// Runs one AI preset over the selection on the device's model,
    /// the mode showing its progress and then the rewrite in place.
    private func runAI(_ preset: AIPromptPreset, paragraphID: String,
                       prefix: String, selected: String, suffix: String) {
        selectionMode = SelectionViewMode(
            paragraphID: paragraphID, prefix: prefix,
            selected: selected, suffix: suffix,
            display: .aiLoading(preset.name))
        Task {
            do {
                let rewritten = try await ReadingAI.rewrite(selected, with: preset)
                if selectionMode?.paragraphID == paragraphID {
                    selectionMode?.display = .aiResult(rewritten)
                }
            } catch {
                if selectionMode?.paragraphID == paragraphID {
                    selectionMode?.display = .aiFailed(error.localizedDescription)
                }
            }
        }
    }

    /// A link clicked inside a paragraph: the `»` stretch toggle opens
    /// and closes its detail, citations open their source card,
    /// everything else opens as links do.
    private func handleLink(_ url: URL) -> Bool {
        if url.scheme == "origami-stretch" {
            let id = String(url.absoluteString.dropFirst("origami-stretch:".count))
            toggleStretch(id)
            return true
        }
        if url.scheme == "origami-conceptcard" {
            let id = String(url.absoluteString.dropFirst("origami-conceptcard:".count))
            if let concept = doc.concepts.first(where: { $0.id == id }) {
                conceptTarget = concept
            }
            return true
        }
        if let conceptID = OrigamiReading.glossaryConceptID(from: url) {
            withAnimation(.easeInOut(duration: 0.15)) {
                if openGlossary.contains(conceptID) {
                    openGlossary.remove(conceptID)
                } else {
                    openGlossary.insert(conceptID)
                }
            }
            return true
        }
        if let noteID = OrigamiReading.noteID(from: url) {
            noteTarget = NoteTarget(noteID: noteID)
            return true
        }
        if let key = OrigamiReading.citationKey(from: url) {
            // The preferred medium opens straight away; Always Ask —
            // or nothing resolvable — shows the card.
            if openSourcesIn != "ask",
               state.autoOpenCitation(key: key, in: doc, preferred: openSourcesIn) {
                return true
            }
            citationTarget = CitationTarget(key: key)
            return true
        }
        return NSWorkspace.shared.open(url)
    }

    /// The rank's point size — the platform's text style plus the
    /// reader's ⌘⇧+/⌘⇧− adjustment.
    private func fontSize(for paragraph: LiquidDoc.Paragraph) -> CGFloat {
        guard let level = paragraph.heading else {
            if let base = latex?.baseSize { return max(CGFloat(base) + fontDelta, 8) }
            return max(NSFont.preferredFont(forTextStyle: .body).pointSize + fontDelta, 8)
        }
        return headingPointSize(level: level)
    }

    /// The heading ladder: level 1 at the title size as ever, each
    /// deeper level about an eighth smaller, never sinking to the
    /// body size — every rank visibly its own. Under a LaTeX profile,
    /// TeX's own ladder over the class size: \section ×1.44,
    /// \subsection ×1.2, the deeper ranks near the body.
    private func headingPointSize(level: Int) -> CGFloat {
        if let base = latex?.baseSize {
            let ladder: [CGFloat] = [1.44, 1.2, 1.1]
            let index = max(level, 1) - 1
            let mult = index < ladder.count ? ladder[index] : 1.0
            return max(CGFloat(base) * mult + fontDelta, 8)
        }
        let top = NSFont.preferredFont(forTextStyle: .title1).pointSize
        let body = NSFont.preferredFont(forTextStyle: .body).pointSize
        let stepped = top * pow(0.88, CGFloat(max(level, 1) - 1))
        return max(max(stepped, body + 1) + fontDelta - 1, 8)
    }

    /// The paragraph's font in the chosen families — headings in the
    /// heading font, everything else in the body font. (A LaTeX style
    /// stamps its roman into these settings when it loads; they stay
    /// the reader's to change.) Under a profile, headings go bold as
    /// TeX has them.
    private func nsFont(for paragraph: LiquidDoc.Paragraph) -> NSFont {
        let family = paragraph.heading != nil ? headingFontName : bodyFontName
        let size = fontSize(for: paragraph)
        var font = NSFont(name: family, size: size)
            ?? NSFont.preferredFont(forTextStyle: paragraph.heading != nil ? .title2 : .body)
        if latex != nil, paragraph.heading != nil {
            let descriptor = font.fontDescriptor.withSymbolicTraits(
                font.fontDescriptor.symbolicTraits.union(.bold))
            font = NSFont(descriptor: descriptor, size: size) ?? font
        }
        return font
    }

    private func paragraphFont(_ paragraph: LiquidDoc.Paragraph) -> Font {
        let family = paragraph.heading != nil ? headingFontName : bodyFontName
        let font = Font.custom(family, size: fontSize(for: paragraph))
        return latex != nil && paragraph.heading != nil ? font.weight(.bold) : font
    }

    /// The leading: the reader's own ⌥⌘± points — or, under a LaTeX
    /// profile, the class's baseline (1.2 × the size, spread applied)
    /// over the face's natural height, approximately.
    private func effectiveLineSpacing(for paragraph: LiquidDoc.Paragraph) -> CGFloat {
        guard let latex, let base = latex.baseSize else { return CGFloat(lineSpacing) }
        let spread = latex.lineSpread ?? 1.0
        return max(CGFloat(base) * CGFloat(1.2 * spread - 1.15), 0)
    }

    /// The air between paragraphs: LaTeX's \parskip when a profile is
    /// on (TeX's default near zero — the indent does the work), the
    /// reading's own air otherwise.
    private var flowSpacing: CGFloat {
        guard let latex else { return 18 }
        return CGFloat(max(latex.parSkip ?? 2, 2))
    }

    /// One point in either direction, for every window at once,
    /// remembered until changed.
    private func stepFontSize(by delta: Double) {
        fontDelta = min(max(fontDelta + delta, -6), 18)
    }

    /// One point of line spacing in either direction, shared and kept.
    private func stepLineSpacing(by delta: Double) {
        lineSpacing = min(max(lineSpacing + delta, 0), 24)
    }

    /// The citation onto the clipboard in both dialects: the readable
    /// block for anyone, and Author's citation payload — the quote and
    /// a full BibTeX entry whose vm-id addresses the original document
    /// and paragraph — so Author pastes it as a real citation.
    private func copyCitation(for paragraph: LiquidDoc.Paragraph) {
        let text = OrigamiReading.citation(for: paragraph, in: doc, view: viewState)
        let payload = OrigamiReading.authorCitationPayload(for: paragraph, in: doc)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let dictionary: [String: Any] = ["Content": payload.content,
                                         "BibTeX": payload.bibtex]
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: dictionary,
                                                        requiringSecureCoding: false) {
            pasteboard.setData(data, forType:
                NSPasteboard.PasteboardType("Liquid Author Citation pasteboard type"))
        }
    }

    /// The paragraph's words as the view functions ask: expanded into
    /// meaning-paragraphs when the model has read it, then broken into
    /// flow lines. Headings stay as written.
    private func readingText(for paragraph: LiquidDoc.Paragraph) -> String {
        guard paragraph.heading == nil else { return paragraph.text }
        var text = paragraph.text
        if expandParagraphs, let split = paragraphSplits[paragraph.id] {
            text = split
        }
        if flowReading {
            text = text.components(separatedBy: "\n\n")
                .map {
                    OrigamiReading.flowText($0, breakOnComma: flowBreakOnComma,
                                            doubleBreakOnPeriod: flowDoubleBreakOnPeriod)
                }
                .joined(separator: "\n\n")
        }
        return text
    }

    /// Reads every long paragraph the model has not yet read, one at a
    /// time, caching where the meaning shifts — the view updates as
    /// each paragraph's breaks arrive.
    private func computeParagraphSplits() {
        guard ReadingAI.isAvailable else {
            flashNotice("The on-device model isn\u{2019}t available, so paragraphs stay as written.")
            expandParagraphs = false
            return
        }
        let candidates = (doc.body ?? []).filter { paragraph in
            paragraph.heading == nil && paragraph.tableID == nil
                && paragraph.text != "---"
                && LiquidDoc.imageReference(in: paragraph.text) == nil
                && paragraphSplits[paragraph.id] == nil
                && wantsParagraphBreaks(paragraph.text)
        }
        guard !candidates.isEmpty else { return }
        flashNotice("Reading for shifts in meaning\u{2026}")
        Task {
            for paragraph in candidates {
                guard expandParagraphs else { break }
                let segments = (try? await ReadingAI.paragraphBreaks(paragraph.text))
                    ?? [paragraph.text]
                paragraphSplits[paragraph.id] = segments.joined(separator: "\n\n")
            }
        }
    }

    /// Only long, multi-sentence paragraphs are worth the model's
    /// reading — the author's own short paragraphs stand as written.
    private func wantsParagraphBreaks(_ text: String) -> Bool {
        guard text.count > 350 else { return false }
        return OrigamiReading.flowLines(text, breakOnComma: false).count
            >= ReadingAI.minimumRun * 2
    }

    /// Asks the model for every substantial paragraph's key sentence —
    /// the one with the most to say — one paragraph at a time, caching
    /// each answer; the bolding lands as the answers arrive.
    private func computeKeySentences() {
        guard ReadingAI.isAvailable else {
            flashNotice("The on-device model isn\u{2019}t available, so nothing can be bolded.")
            boldKeySentences = false
            return
        }
        let candidates = (doc.body ?? []).filter { paragraph in
            paragraph.heading == nil && paragraph.tableID == nil
                && paragraph.text != "---"
                && LiquidDoc.imageReference(in: paragraph.text) == nil
                && keySentences[paragraph.id] == nil
                && wantsKeySentence(paragraph.text)
        }
        guard !candidates.isEmpty else { return }
        flashNotice("Reading for each paragraph\u{2019}s key sentence\u{2026}")
        Task {
            for paragraph in candidates {
                guard boldKeySentences else { break }
                let sentence = (try? await ReadingAI.keySentence(paragraph.text)) ?? nil
                keySentences[paragraph.id] = sentence ?? ""
            }
        }
    }

    /// Only a paragraph of several sentences has filler for its key
    /// sentence to stand out from — one or two stand as written.
    private func wantsKeySentence(_ text: String) -> Bool {
        OrigamiReading.flowLines(text, breakOnComma: false).count
            >= ReadingAI.minimumRun
    }

    /// One line at the bottom of the window, briefly.
    private func flashNotice(_ message: String) {
        Task {
            withAnimation(.easeInOut(duration: 0.2)) { keepNotice = message }
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(.easeInOut(duration: 0.2)) { keepNotice = nil }
        }
    }

    /// The paragraph with its inline conventions rendered — citations in
    /// the reader's style, markdown, the ==marked== style — exact-word
    /// highlights painted in, and the `»` stretch toggle at its end
    /// when a stretch block follows.
    private func inlineText(_ paragraph: LiquidDoc.Paragraph,
                            highlights: [ResolvedAnnotation],
                            trailingStretch: (id: String, run: [LiquidDoc.Paragraph])? = nil,
                            closeStretch: (id: String, isLast: Bool)? = nil)
        -> AttributedString {
        var attributed = rendered(readingText(for: paragraph))
        // The b view function: the paragraph's key sentence — the
        // model's cached choice — stands bold. The sentence is the
        // paragraph's own words, so it is found in the rendered text
        // whatever other view functions are on; flow's line breaks are
        // applied to the sentence first so it still matches.
        if boldKeySentences, paragraph.heading == nil,
           let sentence = keySentences[paragraph.id], !sentence.isEmpty {
            var needle = sentence
            if flowReading {
                needle = OrigamiReading.flowText(needle,
                                                 breakOnComma: flowBreakOnComma,
                                                 doubleBreakOnPeriod: false)
            }
            needle = String(rendered(needle).characters)
            let plain = String(attributed.characters)
            if let range = plain.range(of: needle),
               let attributedRange = Range(range, in: attributed) {
                let runs = attributed[attributedRange].runs
                    .map { ($0.range, $0.inlinePresentationIntent) }
                for (runRange, intent) in runs {
                    attributed[runRange].inlinePresentationIntent =
                        (intent ?? []).union(.stronglyEmphasized)
                }
            }
        }
        for entry in highlights {
            guard let exact = entry.resolution.exact else { continue }
            let plain = String(attributed.characters)
            guard let range = plain.range(of: exact,
                                          options: [.caseInsensitive, .diacriticInsensitive]),
                  let attributedRange = Range(range, in: attributed) else { continue }
            attributed[attributedRange].backgroundColor = Color.yellow.opacity(0.35)
        }
        // The glossary on its terms — the Tab overview when it is up,
        // otherwise brackets or daggers per the Aa menu.
        if glossaryOverviewOn {
            attributed = OrigamiReading.glossaryOverviewed(attributed, in: doc,
                                                           open: openGlossary)
        } else {
            attributed = OrigamiReading.glossaryAnnotated(attributed, in: doc,
                                                          display: glossaryDisplay,
                                                          open: openGlossary)
        }
        if let stretch = trailingStretch,
           let url = URL(string: OrigamiReading.stretchScheme + ":" + stretch.id) {
            let isOpen = openStretch.contains(stretch.id)
            let inlineOpen = isOpen && stretchDisplay == .inline
            // Stretch focus: the revealed words keep their ink; the
            // host's own words grey with the rest of the page.
            if inlineOpen {
                attributed.foregroundColor =
                    themeDimmed ?? Color(nsColor: .secondaryLabelColor)
            }
            // The stretch toggle, inline where Author writes it — at
            // the end of the paragraph the detail expands from, in the
            // body ink like everything else. Open, the frame reads
            // ‹ revealed words ›, every part a click to fold again.
            attributed += AttributedString(" ")
            var toggle = AttributedString(isOpen ? "\u{2039}" : "\u{00BB}")
            toggle.link = url
            attributed += toggle
            // Inline display: the opened detail continues in the same
            // paragraph, no line break.
            if inlineOpen {
                for (index, paragraph) in stretch.run.enumerated() {
                    attributed += AttributedString(" ")
                    attributed += OrigamiReading.stretchRevealed(
                        rendered(paragraph.text), id: stretch.id,
                        closing: index == stretch.run.count - 1)
                }
            }
        }
        // Revealed callout paragraphs close on a click anywhere in
        // them; the last one carries the frame's ›.
        if let closeStretch {
            attributed = OrigamiReading.stretchRevealed(
                attributed, id: closeStretch.id, closing: closeStretch.isLast)
        }
        // The colour-coded view, when the Aa menu has it on: words
        // painted by grammar or meaning, everything already coloured
        // or linked keeping its own.
        if coloringMode != .off {
            attributed = OrigamiReading.colorCoded(
                attributed, mode: coloringMode,
                rules: TextColorRule.decodeList(colorRulesRaw))
        }
        return attributed
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// An annotation paired with where it landed in this document.
private struct ResolvedAnnotation: Identifiable {
    let annotation: WebAnnotation
    let resolution: AnnotationAnchor.Resolution
    var id: String { annotation.id }
}

/// One comment shown beneath its paragraph, with who and when.
private struct CommentBubble: View {
    let entry: ResolvedAnnotation
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.annotation.body?.value ?? "")
            Text(byline)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(.yellow)
                .frame(width: 3)
                .padding(.vertical, 8)
        }
        .contextMenu {
            Button("Remove Comment", systemImage: "trash", role: .destructive,
                   action: onRemove)
        }
    }

    private var byline: String {
        let date = entry.annotation.created.formatted(date: .abbreviated, time: .shortened)
        if let name = entry.annotation.creator?.name, !name.isEmpty {
            return "\(name) · \(date)"
        }
        return date
    }
}

/// The comment sheet: the paragraph being commented on, and the note.
private struct CommentComposer: View {
    let preview: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Comment").font(.headline)
            Text(preview)
                .lineLimit(4)
                .foregroundStyle(.secondary)
            TextField("Your note…", text: $text, axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 440)
    }
}

/// One of the document's own concept definitions — the glossary the
/// author shipped inside the document.
private struct ConceptSheet: View {
    let concept: LiquidDoc.Concept
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(concept.name).font(.title2).bold()
            if !concept.description.isEmpty {
                Text(concept.description)
            } else {
                Text("The document names this concept but carries no description.")
                    .foregroundStyle(.secondary)
            }
            if let tag = concept.tag, !tag.isEmpty {
                Label(tag, systemImage: "tag")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(concept.urls, id: \.self) { url in
                if let link = URL(string: url) {
                    Link(url, destination: link).font(.caption)
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 420, maxWidth: 520)
    }
}

/// One endnote, revealed by its dagger: the note's text with its
/// conventions rendered — links included, live.
private struct EndnoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    let text: AttributedString

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Note").font(.headline)
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 380, maxWidth: 480)
    }
}

/// The card of a cited source, opened by tapping its citation in the
/// body: the reference entry parsed into title, credit, venue, and DOI,
/// the raw BibTeX beneath — and, when the work is in a library here, a
/// way to open it. (KS: resolved through the EPUB Library's own
/// citation resolvers.)
private struct CitationCardSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let doc: LiquidDoc
    let key: String

    private var reference: LiquidDoc.Reference? {
        doc.references.first { $0.id == key }
    }

    private var record: BibTeXRecord? {
        reference.flatMap { BibTeXRecord.records(in: $0.bibtex).first }
    }

    /// The abstract and the entry's other prose read as the body does —
    /// the reading face at the reading size (Settings ▸ Appearance,
    /// ⌘⇧±) — so the card is a page to read, not a footnote. The
    /// title, authors, and year keep their own dress.
    @AppStorage("readingBodyFont") private var bodyFontName = "New York"
    @AppStorage("readingFontDelta") private var fontDelta = 3.0

    private var bodyTextFont: Font {
        Font.custom(bodyFontName,
                    size: max(NSFont.preferredFont(forTextStyle: .body).pointSize
                              + fontDelta, 8))
    }

    /// The summary shown under the authors: the cited work's abstract,
    /// from the shelved work or the entry itself.
    private var summary: String? {
        guard let record else { return nil }
        let text = state.citedWorkAbstract(of: record) ?? record.fields["abstract"]
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The address a vm-id field carries: the cited document in the
    /// origami id space and, after the #, the very paragraph.
    private var citedAddress: (docID: String, paragraphID: String?)? {
        guard let raw = record?.fields["vm-id"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { return nil }
        guard let hash = raw.firstIndex(of: "#") else { return (raw, nil) }
        return (String(raw[..<hash]), String(raw[raw.index(after: hash)...]))
    }

    /// KS: the reference's manifestations — Author's sources array, or
    /// web sources derived from CSL/BibTeX — resolved against the
    /// libraries. See SourceCitations.swift.
    private var sources: [ResolvedCitationSource] {
        state.citationSources(for: key, in: doc)
    }

    @AppStorage("openSourcesIn") private var openSourcesIn = "ask"

    /// One manifestation's row: the Open button (the consulted one
    /// prominent), disabled with its hint when the file isn't here,
    /// badged when it changed since it was cited or stands unverified.
    @ViewBuilder private func sourceRow(_ resolved: ResolvedCitationSource) -> some View {
        HStack(spacing: 8) {
            let label = resolved.source.isConsulted
                ? "Open \(resolved.source.mediumLabel) (consulted)"
                : "Open \(resolved.source.mediumLabel)"
            if resolved.source.isConsulted {
                Button(label) {
                    dismiss()
                    state.open(resolved)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!resolved.isResolvable)
            } else {
                Button(label) {
                    dismiss()
                    state.open(resolved)
                }
                .disabled(!resolved.isResolvable)
            }
            if !resolved.isResolvable {
                Text("not in library")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if case .local(_, let verified, let changed) = resolved.availability {
                if changed {
                    Text("changed since cited")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if !verified, resolved.source.digest != nil {
                    Text("unverified")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let record {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: record.shelvesAsBook ? "book.closed" : "doc.text")
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 44, height: 44)
                        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.title.isEmpty ? "Untitled" : record.title)
                            .font(.title3).bold()
                        if !record.displayAuthors.isEmpty {
                            Text(record.displayAuthors)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let summary {
                    ScrollView {
                        Text(summary)
                            .font(bodyTextFont)
                            .foregroundStyle(AppGreys.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 420)
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    if !record.year.isEmpty {
                        LabeledContent("Year", value: record.year)
                            .font(.callout)
                    }
                    if let venue = [record.fields["journal"], record.fields["booktitle"],
                                    record.fields["series"]]
                        .compactMap({ $0 }).first(where: { !$0.isEmpty }) {
                        LabeledContent("Published in", value: venue)
                            .font(bodyTextFont)
                    }
                    if let doi = record.fields["doi"], !doi.isEmpty,
                       let link = URL(string: "https://doi.org/\(doi)") {
                        LabeledContent("DOI") {
                            Link("doi.org/\(doi)", destination: link)
                        }
                        .font(bodyTextFont)
                    }
                }
            } else if let reference {
                // No parseable BibTeX to render a card from — the raw
                // entry is all there is to show.
                Text("This entry's BibTeX did not parse; the raw entry:")
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(reference.bibtex)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text("The document's reference list has no entry “\(key)”.")
                    .foregroundStyle(.secondary)
            }

            // KS: the manifestations the author consulted — one Open
            // per medium, the consulted one standing primary; a source
            // absent from the library shows greyed, never hidden.
            if !sources.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(sources) { resolved in
                        sourceRow(resolved)
                    }
                    // The viewer's own preference — nothing writes back
                    // into the document. Always Ask keeps this dialog.
                    Picker("Open sources in:", selection: $openSourcesIn) {
                        Text("Always Ask").tag("ask")
                        Text("EPUB").tag("epub")
                        Text("PDF").tag("pdf")
                        Text("Web").tag("web")
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .font(.caption)
                }
            }

            HStack {
                if let reference {
                    Button("Copy BibTeX", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(reference.bibtex, forType: .string)
                    }
                    .help("The reference's BibTeX entry, whole")
                }
                Spacer()
                if let address = citedAddress,
                   let entry = state.index.allByID[address.docID] {
                    // The entry names the cited document by address —
                    // and the library holds it: open it right there,
                    // at the very paragraph the citation quotes.
                    Button("Open Original") {
                        dismiss()
                        state.openInLibrary(entry.doc, fragment: address.paragraphID)
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                } else if let record, state.canOpenCitedWork(record) {
                    // The cited work is on a shelf here: open it whole.
                    Button("Open") {
                        dismiss()
                        state.openCitedWork(record)
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                } else if let url = record?.webURL {
                    Button("Open on the Web") {
                        openURL(url)
                    }
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        // The card grows to hold its abstract at the reading size.
        .frame(minWidth: 480, maxWidth: 680)
    }
}

/// The document's reference list, each entry parsed into a readable
/// citation sentence, the raw BibTeX one copy away.
private struct ReferencesSheet: View {
    let doc: LiquidDoc
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("References (\(doc.references.count))").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            // Numbered as the body's [n] citations count them.
            List(Array(OrigamiReading.readableReferences(of: doc).enumerated()),
                 id: \.element.id) { index, reference in
                Text("[\(index + 1)] \(reference.text)")
                    .textSelection(.enabled)
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(reference.text, forType: .string)
                        }
                    }
            }
        }
        .frame(minWidth: 520, minHeight: 380)
    }
}

// MARK: - Selection view modes

/// One selection viewed differently: the words around it grey out and
/// wait for a click to restore normal reading; the selection itself
/// shows as Flow lines or as the on-device model's rewrite.
private struct SelectionViewMode {
    enum Display: Equatable {
        /// The selection broken into reading lines at . and , marks.
        case flow
        /// The named AI verb is still thinking.
        case aiLoading(String)
        /// The model's rewrite, read in place.
        case aiResult(String)
        /// Why there is no rewrite.
        case aiFailed(String)
    }

    let paragraphID: String
    let prefix: String
    let selected: String
    let suffix: String
    var display: Display
}

/// The mode's rendering of its paragraph: grey unselected words either
/// side (click to leave the mode), the transformed selection between.
private struct SelectionModeView: View {
    let mode: SelectionViewMode
    let font: Font
    let exit: () -> Void
    @AppStorage("flowBreakOnComma") private var flowBreakOnComma = true
    @AppStorage("flowDoubleBreakOnPeriod") private var flowDoubleBreakOnPeriod = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            greyText(mode.prefix)
            switch mode.display {
            case .flow:
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(OrigamiReading.flowLines(
                        mode.selected,
                        breakOnComma: flowBreakOnComma,
                        doubleBreakOnPeriod: flowDoubleBreakOnPeriod).enumerated()),
                            id: \.offset) { _, line in
                        // An empty entry is the double break: a blank
                        // line between sentences.
                        Text(line.isEmpty ? " " : line).font(font)
                    }
                }
            case .aiLoading(let name):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("\(name)…").foregroundStyle(.secondary)
                }
            case .aiResult(let text):
                Text(text).font(font)
            case .aiFailed(let reason):
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            greyText(mode.suffix)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func greyText(_ text: String) -> some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            Text(trimmed)
                .font(font)
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
                .onTapGesture(perform: exit)
        }
    }
}

extension View {
    /// While a stretchtext is open, everything but the revealed words
    /// reads grey — a visual focus, clicks unchanged.
    @ViewBuilder
    fileprivate func dimmedForStretch(_ active: Bool) -> some View {
        if active {
            self.grayscale(1).opacity(0.4)
        } else {
            self
        }
    }

    /// While a selection view mode is on, everything unselected greys
    /// out and any click on it leaves the mode.
    @ViewBuilder
    fileprivate func greyedOut(_ active: Bool, exit: @escaping () -> Void) -> some View {
        if active {
            self
                .grayscale(1)
                .opacity(0.35)
                .overlay {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: exit)
                }
        } else {
            self
        }
    }
}

// MARK: - The selectable paragraph

/// One verb of the paragraph menu, as data — built once, rendered as an
/// NSMenu on the selectable paragraphs and as SwiftUI items on the
/// table fallback.
private enum ParagraphMenuEntry {
    case action(title: String, symbol: String, run: () -> Void)
    case submenu(title: String, symbol: String, items: [(String, () -> Void)])
    case separator
}

/// A paragraph as an NSTextView: text selects like any Mac text, but
/// right-click shows only the reading menu — SwiftUI's selectable Text
/// always merges the system's items (Look Up, Translate, Services…)
/// into a custom context menu; AppKit lets the menu be replaced whole.
/// Links route through `onLink`, so citations still open their source
/// card.
private struct SelectableParagraph: NSViewRepresentable {
    let attributed: AttributedString
    let baseFont: NSFont
    /// Extra points between lines (⌥⌘+/⌥⌘−).
    let lineSpacing: CGFloat
    /// The LaTeX dress: justified with hyphenation, first lines
    /// indented at \parindent.
    var justified = false
    var firstLineIndent: CGFloat = 0
    /// The theme's ink for this paragraph; nil reads as the platform's.
    let inkColor: NSColor?
    /// Stretch focus: everything greys except the stretch's own
    /// controls. Ink only — a compositing effect would freeze the
    /// AppKit view into a picture and swallow its clicks.
    let dimmed: Bool
    let dimInk: NSColor
    let entries: [ParagraphMenuEntry]
    /// Extra verbs built at right-click time from the live selection —
    /// the view options over selected text (Flow, the AI submenu).
    let selectionEntries: (String, NSRange) -> [ParagraphMenuEntry]
    let onLink: (URL) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MenuTextView {
        let view = MenuTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.isHorizontallyResizable = false
        // Links read in the body ink, not browser blue — the run's own
        // attributes carry the colour and a quiet underline, so the
        // view must not paint links over them.
        view.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        view.delegate = context.coordinator
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: MenuTextView, context: Context) {
        context.coordinator.entries = entries
        context.coordinator.selectionEntries = selectionEntries
        context.coordinator.onLink = onLink
        let converted = converted()
        // Replacing the storage drops any live selection; only real
        // content changes are worth that.
        if view.textStorage?.isEqual(to: converted) != true {
            view.textStorage?.setAttributedString(converted)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MenuTextView,
                      context: Context) -> CGSize? {
        guard let container = nsView.textContainer,
              let layout = nsView.layoutManager else { return nil }
        // Measure at the proposed width; when none is proposed, at the
        // width the view actually has, so every pass agrees.
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            ?? (nsView.bounds.width > 0 ? nsView.bounds.width : 680)
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: width, height: ceil(used.height))
    }

    /// The AttributedString with its semantic runs resolved into AppKit
    /// attributes: presentation intents to bold/italic/monospace on the
    /// base font, colours and links carried across.
    private func converted() -> NSAttributedString {
        let out = NSMutableAttributedString()
        for run in attributed.runs {
            let text = String(attributed.characters[run.range])
            var font = baseFont
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    font = .monospacedSystemFont(ofSize: baseFont.pointSize * 0.92,
                                                 weight: .regular)
                }
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty {
                    let descriptor = font.fontDescriptor.withSymbolicTraits(
                        font.fontDescriptor.symbolicTraits.union(traits))
                    font = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
                }
            }
            var ink = run.foregroundColor.map(NSColor.init) ?? inkColor ?? .labelColor
            if dimmed, run.link?.scheme != "origami-stretch" {
                ink = dimInk
            }
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = lineSpacing
            if justified {
                paragraphStyle.alignment = .justified
                paragraphStyle.hyphenationFactor = 0.9
                paragraphStyle.firstLineHeadIndent = firstLineIndent
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: ink,
                .paragraphStyle: paragraphStyle,
            ]
            if let background = run.backgroundColor {
                attributes[.backgroundColor] = NSColor(background)
            }
            if let link = run.link {
                // Body ink with a quiet underline — the format's rule
                // for links, never browser blue. The stretch toggle
                // and the glossary daggers are controls, not
                // references: no underline.
                attributes[.link] = link
                if link.scheme != "origami-stretch", link.scheme != "origami-gloss",
                   link.scheme != "origami-note", link.scheme != "origami-conceptcard" {
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    attributes[.underlineColor] = ink.withAlphaComponent(0.35)
                }
            }
            out.append(NSAttributedString(string: text, attributes: attributes))
        }
        return out
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var entries: [ParagraphMenuEntry] = []
        var selectionEntries: (String, NSRange) -> [ParagraphMenuEntry] = { _, _ in [] }
        var onLink: (URL) -> Bool = { _ in false }

        func textView(_ textView: NSTextView, clickedOnLink link: Any,
                      at charIndex: Int) -> Bool {
            guard let url = link as? URL else { return false }
            return onLink(url)
        }

        /// The context menu, built fresh on each right-click — the
        /// paragraph's verbs, then the selection's view options when
        /// words are selected. Nothing of the system's.
        func makeMenu(for textView: NSTextView) -> NSMenu {
            let menu = NSMenu()
            var all = entries
            let range = textView.selectedRange()
            if range.length > 0 {
                all += selectionEntries(textView.string, range)
            }
            for entry in all {
                switch entry {
                case .action(let title, let symbol, let run):
                    menu.addItem(item(title: title, symbol: symbol, run: run))
                case .submenu(let title, let symbol, let items):
                    let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    parent.image = NSImage(systemSymbolName: symbol,
                                           accessibilityDescription: nil)
                    let submenu = NSMenu()
                    for (subtitle, run) in items {
                        submenu.addItem(item(title: subtitle, symbol: nil, run: run))
                    }
                    parent.submenu = submenu
                    menu.addItem(parent)
                case .separator:
                    menu.addItem(.separator())
                }
            }
            return menu
        }

        private func item(title: String, symbol: String?,
                          run: @escaping () -> Void) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(fire(_:)),
                                  keyEquivalent: "")
            item.target = self
            if let symbol {
                item.image = NSImage(systemSymbolName: symbol,
                                     accessibilityDescription: nil)
            }
            item.representedObject = MenuClosure(run)
            return item
        }

        @objc private func fire(_ sender: NSMenuItem) {
            (sender.representedObject as? MenuClosure)?.run()
        }
    }

    /// A closure a menu item can carry.
    final class MenuClosure {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    /// NSTextView whose context menu is the coordinator's, whole, and
    /// whose reading controls act on the press itself.
    final class MenuTextView: NSTextView {
        weak var coordinator: Coordinator?

        /// The wrap follows the frame the moment the frame changes —
        /// measured height and drawn text can never disagree, which
        /// would read as overlapping paragraphs (text views do not
        /// clip). Width tracking is kept manual so measurement passes
        /// at other widths stay undisturbed.
        override func setFrameSize(_ newSize: NSSize) {
            if let container = textContainer, container.size.width != newSize.width {
                container.size = NSSize(width: newSize.width,
                                        height: .greatestFiniteMagnitude)
            }
            super.setFrameSize(newSize)
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            coordinator?.makeMenu(for: self)
        }

        /// The document's own controls — the stretch toggles and
        /// revealed text, glossary marks, endnote daggers, citations —
        /// respond to the mouse-down directly, not the link-click
        /// machinery, so they work wherever the text sits.
        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if let layoutManager, let textContainer, let storage = textStorage,
               storage.length > 0 {
                var fraction: CGFloat = 0
                let index = layoutManager.characterIndex(
                    for: point, in: textContainer,
                    fractionOfDistanceBetweenInsertionPoints: &fraction)
                if index < storage.length,
                   let url = storage.attribute(.link, at: index,
                                               effectiveRange: nil) as? URL,
                   ["origami-stretch", "origami-gloss", "origami-note", "origami-cite",
                    "origami-conceptcard"]
                       .contains(url.scheme ?? "") {
                    let glyphRange = layoutManager.glyphRange(
                        forCharacterRange: NSRange(location: index, length: 1),
                        actualCharacterRange: nil)
                    let rect = layoutManager.boundingRect(forGlyphRange: glyphRange,
                                                          in: textContainer)
                    if rect.insetBy(dx: -3, dy: -3).contains(point) {
                        _ = coordinator?.onLink(url)
                        return
                    }
                }
            }
            super.mouseDown(with: event)
        }
    }
}

// MARK: - The window's state

/// What the reading measure needs to know about its window.
struct ReaderWindowState: Equatable {
    var isFullScreen = false
    var isBuiltInDisplay = true
    var screenWidth: CGFloat = 1512
    /// The hosting window's number, so event monitors act only on
    /// their own window's events.
    var windowNumber = 0
}

/// Reports the hosting window's full-screen state and display — on
/// arrival, on enter/exit, and when the window changes screens.
private struct ReaderWindowWatcher: NSViewRepresentable {
    let onChange: (ReaderWindowState) -> Void

    func makeNSView(context: Context) -> WatcherView {
        let view = WatcherView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: WatcherView, context: Context) {
        view.onChange = onChange
    }

    final class WatcherView: NSView {
        var onChange: ((ReaderWindowState) -> Void)?
        private var observers: [any NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            report()
            for name in [NSWindow.didEnterFullScreenNotification,
                         NSWindow.didExitFullScreenNotification,
                         NSWindow.didChangeScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.report()
                })
            }
        }

        private func report() {
            guard let window else { return }
            var state = ReaderWindowState()
            state.isFullScreen = window.styleMask.contains(.fullScreen)
            state.windowNumber = window.windowNumber
            if let screen = window.screen {
                state.screenWidth = screen.frame.width
                let number = (screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                    .uint32Value ?? 0
                state.isBuiltInDisplay = CGDisplayIsBuiltin(number) != 0
            }
            DispatchQueue.main.async { [onChange] in
                onChange?(state)
            }
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
