//
//  MapDocumentIO.swift
//  Knowledge Space
//
//  One door for every map document format. The Map engine speaks
//  KnowledgeMapDocument.Contents; each format brings its own coder, and
//  this router detects what a URL holds — by content where it can,
//  never trusting the name alone — loads through the right coder, and
//  saves back only in the format the document arrived in.
//
//  Formats:
//  - Knowledge Space JSON (`.liquid.json`) — live today, via LiquidDoc.
//  - Author `.liquid` package — detected and routed; reader coming.
//

import Foundation

/// The serializations a map document can arrive in.
enum MapDocumentFormat: String {
    /// Knowledge Space macOS JSON — a `.liquid.json` file.
    case knowledgeSpaceJSON
    /// An Author document — a `.liquid` package.
    case authorLiquid

    var displayName: String {
        switch self {
        case .knowledgeSpaceJSON: return "Knowledge Space JSON"
        case .authorLiquid: return "Author document"
        }
    }
}

enum MapDocumentIOError: Error, CustomStringConvertible {
    case unrecognized(URL)
    case notYetSupported(MapDocumentFormat)

    var description: String {
        switch self {
        case .unrecognized(let url):
            return "'\(url.lastPathComponent)' is not a map document Knowledge Space recognizes."
        case .notYetSupported(let format):
            return "\(format.displayName)s are recognized but cannot be opened yet."
        }
    }
}

/// A format's reader/writer pair. Every coder produces and consumes the
/// same in-memory contents; formats exist only at this seam, and no
/// coder shares state with another.
protocol MapDocumentCoding {
    static var format: MapDocumentFormat { get }
    static func load(from url: URL) throws -> KnowledgeMapDocument.Contents
    static func save(_ contents: KnowledgeMapDocument.Contents, to url: URL) throws
}

enum MapDocumentIO {

    /// What the URL holds, judged by what's actually there: a `.liquid`
    /// package is an Author document; a regular file whose bytes read
    /// as a JSON object is a Knowledge Space document, whatever its
    /// name. A misnamed or unreadable file fails loudly at open rather
    /// than half-parsing.
    static func detectFormat(at url: URL) -> MapDocumentFormat? {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            return url.pathExtension.lowercased() == "liquid" ? .authorLiquid : nil
        }
        if exists, let data = try? Data(contentsOf: url, options: [.alwaysMapped]),
           looksLikeJSONObject(data) {
            return .knowledgeSpaceJSON
        }
        // Not yet downloaded (iCloud placeholder) or empty: fall back to
        // the honest name, and let the coder report what went wrong.
        return LiquidDoc.isDocumentFile(url) ? .knowledgeSpaceJSON : nil
    }

    /// Loads whatever the URL holds, reporting the format it arrived in
    /// so saves can keep faith with it.
    static func load(from url: URL) throws -> (contents: KnowledgeMapDocument.Contents, format: MapDocumentFormat) {
        guard let format = detectFormat(at: url) else {
            throw MapDocumentIOError.unrecognized(url)
        }
        return (try coder(for: format).load(from: url), format)
    }

    /// Saves in the given format — the one the document arrived in.
    /// Converting between formats is a deliberate act (a future
    /// Save As / Convert), never a side effect of saving.
    static func save(_ contents: KnowledgeMapDocument.Contents, to url: URL, format: MapDocumentFormat) throws {
        try coder(for: format).save(contents, to: url)
    }

    private static func coder(for format: MapDocumentFormat) throws -> MapDocumentCoding.Type {
        switch format {
        case .knowledgeSpaceJSON:
            return KnowledgeSpaceJSONCoder.self
        case .authorLiquid:
            // The Author coder plugs in here when it exists.
            throw MapDocumentIOError.notYetSupported(.authorLiquid)
        }
    }

    /// JSON begins with an object brace once whitespace and a BOM are
    /// set aside.
    private static func looksLikeJSONObject(_ data: Data) -> Bool {
        var bytes = Array(data.prefix(64))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes.removeFirst(3)
        }
        for byte in bytes {
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D:
                continue
            case UInt8(ascii: "{"):
                return true
            default:
                return false
            }
        }
        return false
    }
}

/// Knowledge Space's own JSON (`.liquid.json`), carried by the existing
/// LiquidDoc bridge in KnowledgeMapDocument.
enum KnowledgeSpaceJSONCoder: MapDocumentCoding {
    static let format = MapDocumentFormat.knowledgeSpaceJSON

    static func load(from url: URL) throws -> KnowledgeMapDocument.Contents {
        try KnowledgeMapDocument.load(from: url)
    }

    static func save(_ contents: KnowledgeMapDocument.Contents, to url: URL) throws {
        try KnowledgeMapDocument.save(contents, to: url)
    }
}
