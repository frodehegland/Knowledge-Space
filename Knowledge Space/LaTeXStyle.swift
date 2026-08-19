import SwiftUI
import AppKit
import UniformTypeIdentifiers

// A LaTeX style guide, read for its typographic decisions — the class
// size, the leading, the measure, the faces, the paragraph shape —
// and laid over the book reader so an EPUB reads as though TeX had
// set it: justified and hyphenated, first lines indented, the text
// column at \textwidth. No TeX runs; the style file is read as the
// text it is, and only the decisions the reflowable page can honour
// are taken. Loaded and inspected in Settings ▸ LaTeX.

/// What was read from the style guide — every field optional, since a
/// style says only what it says.
nonisolated struct LaTeXStyleProfile: Codable, Equatable {
    /// The style file's name, shown in Settings.
    var name: String
    /// The class's body size in points (10/11/12pt, or \fontsize).
    var baseSize: Double?
    /// \linespread / \baselinestretch / setspace's spacings.
    var lineSpread: Double?
    /// \textwidth (or geometry's), in TeX points.
    var textWidth: Double?
    /// The roman the packages ask for, resolved to an installed face.
    var bodyFace: String?
    /// \parindent in points.
    var parIndent: Double?
    /// \parskip in points.
    var parSkip: Double?
    /// The class asked for two columns — the Horizontal mode's hint.
    var twoColumn: Bool = false
    /// One readable line per decision read, for the Settings list.
    var notes: [String] = []

    static let storageKey = "latexStyleProfile"
    static let enabledKey = "latexTypesetting"

    func encoded() -> String {
        (try? JSONEncoder().encode(self))
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    static func decode(_ stored: String?) -> LaTeXStyleProfile? {
        guard let stored, let data = stored.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(LaTeXStyleProfile.self, from: data)
    }
}

nonisolated enum LaTeXStyle {

    /// The style guide read for its decisions. Comments fall away
    /// first; every recognised command adds its readable note.
    static func parse(_ raw: String, name: String) -> LaTeXStyleProfile {
        // % starts a comment to the line's end (\% is a literal).
        let text = raw
            .replacingOccurrences(of: "\\%", with: "\u{1}")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                if let mark = line.firstIndex(of: "%") {
                    return String(line[..<mark])
                }
                return String(line)
            }
            .joined(separator: "\n")
            .replacingOccurrences(of: "\u{1}", with: "\\%")

        var profile = LaTeXStyleProfile(name: name)

        // The class's body size: \documentclass[11pt,a4paper]{article}.
        if let options = first(#"\\(?:documentclass|LoadClass)\s*\[([^\]]*)\]"#, in: text) {
            for size in [10.0, 11.0, 12.0] where options.contains("\(Int(size))pt") {
                profile.baseSize = size
                profile.notes.append("Body size \(Int(size))pt — the class option.")
            }
            if options.contains("twocolumn") {
                profile.twoColumn = true
                profile.notes.append("Two columns — the Horizontal mode reads closest.")
            }
        }

        // The leading: \linespread, \baselinestretch, or setspace.
        if let spread = first(#"\\linespread\s*\{([0-9.]+)\}"#, in: text)
            .flatMap(Double.init)
            ?? first(#"\\baselinestretch\s*\}?\s*\{([0-9.]+)\}"#, in: text)
                .flatMap(Double.init) {
            profile.lineSpread = spread
            profile.notes.append("Line spread \(spread) — \\linespread.")
        } else if text.contains("\\doublespacing") {
            profile.lineSpread = 1.667
            profile.notes.append("Double spacing — setspace.")
        } else if text.contains("\\onehalfspacing") {
            profile.lineSpread = 1.25
            profile.notes.append("One-and-a-half spacing — setspace.")
        }

        // The measure: \setlength{\textwidth}{345pt} or geometry's
        // textwidth=13cm / width=13cm.
        if let width = length("textwidth", in: text)
            ?? first(#"(?:textwidth|width)\s*=\s*([0-9.]+\s*[a-z]+)"#, in: text)
                .flatMap(dimension) {
            profile.textWidth = width
            profile.notes.append("Measure \(Int(width))pt — \\textwidth.")
        }

        // The paragraph's shape.
        if let indent = length("parindent", in: text) {
            profile.parIndent = indent
            profile.notes.append("Paragraph indent \(Int(indent))pt — \\parindent.")
        }
        if let skip = length("parskip", in: text) {
            profile.parSkip = skip
            profile.notes.append("Paragraph skip \(Int(skip))pt — \\parskip.")
        }

        // The roman. fontspec's named face first; else the classic
        // packages; else Computer Modern stands as the default.
        if let face = first(#"\\setmainfont\s*(?:\[[^\]]*\])?\s*\{([^}]+)\}"#, in: text) {
            let resolved = resolveFace([face]) ?? face
            profile.bodyFace = resolved
            profile.notes.append("Face \(resolved) — \\setmainfont.")
        } else if matchesPackage(text, ["times", "newtxtext", "mathptmx", "txfonts"]) {
            profile.bodyFace = resolveFace(["Times New Roman", "Times"])
            profile.notes.append("Times — the class's font package.")
        } else if matchesPackage(text, ["palatino", "newpxtext", "mathpazo", "pxfonts"]) {
            profile.bodyFace = resolveFace(["Palatino", "Book Antiqua"])
            profile.notes.append("Palatino — the class's font package.")
        } else if matchesPackage(text, ["charter", "XCharter"]) {
            profile.bodyFace = resolveFace(["Charter", "Bitstream Charter"])
            profile.notes.append("Charter — the class's font package.")
        } else if matchesPackage(text, ["libertine", "libertinus"]) {
            profile.bodyFace = resolveFace(["Linux Libertine", "Libertinus Serif"])
            profile.notes.append("Libertine — the class's font package.")
        } else {
            profile.bodyFace = resolveFace(
                ["Latin Modern Roman", "CMU Serif", "New York"])
            profile.notes.append("Computer Modern — TeX's own; "
                + (profile.bodyFace.map { "\($0) stands in." } ?? "the serif stands in."))
        }

        if text.contains("\\twocolumn") { profile.twoColumn = true }

        if profile.baseSize == nil {
            profile.baseSize = 10
            profile.notes.append("Body size 10pt — TeX's default, nothing said otherwise.")
        }
        return profile
    }

    /// \setlength{\NAME}{value} — the value in points.
    private static func length(_ name: String, in text: String) -> Double? {
        first(#"\\setlength\s*\{\\"# + name + #"\}\s*\{([^}]+)\}"#, in: text)
            .flatMap(dimension)
    }

    /// "345pt", "13cm", "1.5in" → TeX points; em/ex (font-relative)
    /// are not ours to compute.
    static func dimension(_ raw: String) -> Double? {
        let cleaned = raw.trimmingCharacters(in: .whitespaces)
        guard let match = firstMatch(#"^([0-9.]+)\s*([a-z]+)"#, in: cleaned),
              let value = Double(match.1) else { return nil }
        switch match.2 {
        case "pt": return value
        case "bp": return value * 1.00375
        case "pc": return value * 12
        case "mm": return value * 2.845
        case "cm": return value * 28.452
        case "in": return value * 72.27
        default: return nil
        }
    }

    private static func matchesPackage(_ text: String, _ names: [String]) -> Bool {
        names.contains { name in
            firstMatch(#"\\(?:usepackage|RequirePackage)\s*(?:\[[^\]]*\])?\s*\{[^}]*\b"#
                       + NSRegularExpression.escapedPattern(for: name)
                       + #"\b[^}]*\}"#, in: text) != nil
        }
    }

    /// The first installed face from the candidates.
    static func resolveFace(_ candidates: [String]) -> String? {
        candidates.first { NSFont(name: $0, size: 12) != nil }
    }

    private static func first(_ pattern: String, in text: String) -> String? {
        firstMatch(pattern, in: text)?.1
    }

    private static func firstMatch(_ pattern: String, in text: String)
        -> (whole: String, String, String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        func group(_ index: Int) -> String {
            guard index < match.numberOfRanges,
                  let r = Range(match.range(at: index), in: text) else { return "" }
            return String(text[r])
        }
        return (group(0), group(1), group(2))
    }
}

// MARK: - Settings ▸ LaTeX

struct LaTeXSettingsView: View {
    @AppStorage(LaTeXStyleProfile.enabledKey) private var enabled = false
    @AppStorage(LaTeXStyleProfile.storageKey) private var profileRaw = ""

    private var profile: LaTeXStyleProfile? {
        LaTeXStyleProfile.decode(profileRaw)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Typeset reading like LaTeX", isOn: $enabled)
                    .disabled(profile == nil)
                HStack {
                    Button("Load Style Guide…") { loadStyle() }
                    Spacer()
                    if profile != nil {
                        Button("Clear") {
                            profileRaw = ""
                            enabled = false
                        }
                    }
                }
                if let profile {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(profile.name)
                            .font(.subheadline.weight(.semibold))
                        ForEach(profile.notes, id: \.self) { note in
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("LaTeX")
            } footer: {
                Text("Load a LaTeX style guide — a .cls, .sty, or preamble — and the book reader conforms to its decisions: the class's body size and leading, the \\textwidth measure, the font packages' roman, justified and hyphenated paragraphs with \\parindent first lines. No TeX runs; the style file is read as text and only what a reflowable page can honour is taken. A testing door — the reading's own type settings stand when this is off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func loadStyle() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        var types: [UTType] = [.plainText]
        if let cls = UTType(filenameExtension: "cls") { types.append(cls) }
        if let sty = UTType(filenameExtension: "sty") { types.append(sty) }
        if let tex = UTType(filenameExtension: "tex") { types.append(tex) }
        panel.allowedContentTypes = types
        panel.message = "Choose a LaTeX style guide — a .cls, .sty, or .tex preamble."
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        let profile = LaTeXStyle.parse(String(decoding: data, as: UTF8.self),
                                       name: url.lastPathComponent)
        profileRaw = profile.encoded()
        enabled = true
        // The style's roman becomes the reading's own font settings —
        // visible in Settings ▸ Appearance and the reader's to change
        // afterwards. The style stamps them once at loading; it never
        // holds them.
        if let face = profile.bodyFace {
            UserDefaults.standard.set(face, forKey: "readingBodyFont")
            UserDefaults.standard.set(face, forKey: "readingHeadingFont")
        }
    }
}
