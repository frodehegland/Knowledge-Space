import Foundation

// Ported from Augmented Library's InteratlasCitation.swift — access
// levels dropped, and the real link host added to the placeholder
// (worth carrying back). A fix here should be carried across.

/// The Interatlas Link: a plain https URL on the Interatlas link domain,
/// path `/v1/<realm>`, whose query captures a complete view state (layers,
/// time, camera, selection, marks). Recognition is by host alone — the
/// format's rule is never to parse deeper just to recognise one — and
/// opening is plain `openURL`; universal-link routing does the rest.
nonisolated enum InteratlasLink {

    /// The hosts recognised as Interatlas link domains: the live one,
    /// and the spec's placeholder kept for documents written to it.
    static let hosts: Set<String> = [
        "link.augmentedtext.com",
        "link.interatlas.example",
    ]

    /// Whether a URL is an Interatlas Link — a match on the known link
    /// host, nothing more.
    static func isInteratlasLink(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return hosts.contains(host)
    }

    /// Convenience for link fields kept as text on records.
    static func isInteratlasLink(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)) else { return false }
        return isInteratlasLink(url)
    }

    /// The link in its scheme form: the https URL with only its scheme
    /// swapped to `interatlas://` — the convention Interatlas's receiver
    /// reads, one parser serving both forms. Nil when the URL cannot be
    /// recomposed.
    static func schemed(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        components.scheme = "interatlas"
        return components.url
    }
}

/// The Liquid view link: the same link domain, path `/liquid/…`, minted
/// by Author's 3D view export ("View: …" citations). The URL carries the
/// whole view state; the receiving app is Liquid, not Interatlas —
/// recognition is the known host plus the /liquid/ path, still never
/// parsing deeper than needed to recognise.
nonisolated enum LiquidViewLink {

    /// Whether a URL is a Liquid view link — the shared link domain
    /// carrying the /liquid/ path.
    static func isLiquidViewLink(_ url: URL) -> Bool {
        guard InteratlasLink.isInteratlasLink(url) else { return false }
        return url.path.lowercased().hasPrefix("/liquid/")
    }

    /// Convenience for link fields kept as text on records.
    static func isLiquidViewLink(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)) else { return false }
        return isLiquidViewLink(url)
    }

    /// The link in its scheme forms, newest first: `liquidinfo://` —
    /// the scheme Liquid Information declares — then the older
    /// `liquid://` that LiquidView claimed, so a receiver is offered
    /// whichever door it actually has.
    static func schemedForms(_ url: URL) -> [URL] {
        ["liquidinfo", "liquid"].compactMap { scheme in
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            else { return nil }
            components.scheme = scheme
            return components.url
        }
    }

    /// The primary scheme form (`liquidinfo://`), for the platforms
    /// that try one scheme and fall back to the https link.
    static func schemed(_ url: URL) -> URL? {
        schemedForms(url).first
    }
}

/// Reads the citation Interatlas embeds in its screenshots: the BibTeX
/// entry carried in a PNG iTXt chunk under the keyword `visual-meta`,
/// mirrored in XMP. Walks the PNG's chunk structure directly — ImageIO
/// does not surface arbitrary iTXt keywords — and is tolerant by design:
/// a PNG without the chunk, or with one that does not read, is simply an
/// ordinary image (nil), never an error.
nonisolated enum PNGCitation {

    private static let pngSignature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    private static let visualMetaKeyword = "visual-meta"
    private static let xmpKeyword = "XML:com.adobe.xmp"

    /// The embedded citation text: the `visual-meta` iTXt (or tEXt) chunk's
    /// value if present, else the XMP packet mirroring it — the caller runs
    /// a BibTeX scan over whichever comes back. Nil for an ordinary PNG,
    /// a non-PNG, or a file too damaged to walk.
    static func citationText(inPNGData data: Data) -> String? {
        let bytes = [UInt8](data)
        guard bytes.count > pngSignature.count,
              Array(bytes[0..<pngSignature.count]) == pngSignature else { return nil }

        var xmpFallback: String?
        var offset = pngSignature.count
        // Each chunk: 4-byte big-endian length, 4-byte type, payload, CRC.
        while offset + 12 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                       | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            guard length >= 0, offset + 12 + length <= bytes.count else { break }
            let type = String(bytes: bytes[(offset + 4)..<(offset + 8)], encoding: .ascii) ?? ""
            if type == "IEND" { break }
            let body = Array(bytes[(offset + 8)..<(offset + 8 + length)])
            switch type {
            case "iTXt":
                if let (keyword, text) = iTXtEntry(body) {
                    if keyword == visualMetaKeyword { return text }
                    if keyword == xmpKeyword, xmpFallback == nil { xmpFallback = text }
                }
            case "tEXt":
                if let (keyword, text) = tEXtEntry(body), keyword == visualMetaKeyword {
                    return text
                }
            default:
                break
            }
            offset += 12 + length
        }
        return xmpFallback
    }

    /// One iTXt payload: keyword NUL, compression flag and method,
    /// language tag NUL, translated keyword NUL, UTF-8 text. Compressed
    /// entries are skipped — Interatlas writes its citation uncompressed.
    private static func iTXtEntry(_ body: [UInt8]) -> (keyword: String, text: String)? {
        guard let keywordEnd = body.firstIndex(of: 0),
              let keyword = String(bytes: body[0..<keywordEnd], encoding: .isoLatin1)
        else { return nil }
        var index = keywordEnd + 1
        guard index + 2 <= body.count else { return nil }
        let compressed = body[index] != 0
        index += 2
        guard !compressed else { return nil }
        // Skip the language tag, then the translated keyword.
        for _ in 0..<2 {
            while index < body.count, body[index] != 0 { index += 1 }
            guard index < body.count else { return nil }
            index += 1
        }
        guard let text = String(bytes: body[index...], encoding: .utf8) else { return nil }
        return (keyword, text)
    }

    /// One tEXt payload: keyword NUL, Latin-1 text.
    private static func tEXtEntry(_ body: [UInt8]) -> (keyword: String, text: String)? {
        guard let keywordEnd = body.firstIndex(of: 0),
              let keyword = String(bytes: body[0..<keywordEnd], encoding: .isoLatin1),
              let text = String(bytes: body[(keywordEnd + 1)...], encoding: .isoLatin1)
        else { return nil }
        return (keyword, text)
    }
}
