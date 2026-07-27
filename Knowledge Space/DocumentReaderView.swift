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
            if let body = doc.body {
                let appendixIDs = doc.visualMetaParagraphIDs
                    .union(doc.analysisParagraphIDs)
                ForEach(body) { paragraph in
                    ParagraphView(paragraph: paragraph,
                                  isAppendix: appendixIDs.contains(paragraph.id),
                                  isHighlighted: paragraph.id == state.pendingFragment,
                                  flowed: state.flowReading)
                        .id(paragraph.id)
                }
            } else if let wraps = doc.wraps {
                sidecarView(wraps)
            }
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
    let paragraph: LiquidDoc.Paragraph
    var isAppendix = false
    var isHighlighted = false
    /// Flow: break dense prose open for reading (sentences, clauses,
    /// parentheses). Display only; headings and the appendix are left
    /// alone.
    var flowed = false

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
        } else {
            VStack(alignment: .leading, spacing: 3) {
                if let speaker = paragraph.speaker {
                    Text(speaker)
                        .font(.system(size: 13 * scale, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
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
