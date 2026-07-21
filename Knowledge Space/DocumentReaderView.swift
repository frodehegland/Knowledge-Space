import SwiftUI

/// The reading view for one Origami Document: serif typography, heading
/// scale, live address links, the Visual-Meta appendix de-emphasized, and
/// backlinks gathered from the library index. Arrival by fragment link
/// scrolls to the paragraph and flashes it.
struct DocumentReaderView: View {
    @Environment(AppState.self) private var state
    let doc: LiquidDoc

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if let body = doc.body {
                        let appendixIDs = doc.visualMetaParagraphIDs
                        ForEach(body) { paragraph in
                            ParagraphView(paragraph: paragraph,
                                          isAppendix: appendixIDs.contains(paragraph.id),
                                          isHighlighted: paragraph.id == state.pendingFragment)
                                .id(paragraph.id)
                        }
                    } else if let wraps = doc.wraps {
                        sidecarView(wraps)
                    }
                    backlinksSection
                }
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(24)
            }
            .onAppear { scrollToPendingFragment(proxy) }
            .onChange(of: state.pendingFragment) { scrollToPendingFragment(proxy) }
        }
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

    private var header: some View {
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
                    Text(location)
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
            Divider()
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
                .font(.system(size: 19, weight: .bold, design: .serif))
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

    private var isRule: Bool {
        let text = paragraph.displayText
        return text.count >= 3 && text.allSatisfy { $0 == "-" }
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
                Text(paragraph.renderedText)
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
