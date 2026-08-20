//
//  EPUBBookletRenderer.swift
//
//  Shared between Author (Liquid Author/Publishing/) and Knowledge
//  Space — keep the two copies identical; Author's is canonical.
//
//  Renders an .epub file to a paginated PDF so it can be imposed as a
//  booklet (see BookletImposer). Self-contained: a minimal zip reader
//  (EPUB entries are stored or raw-deflate, which Compression decodes),
//  the container/OPF spine walk, HTML import, and TextKit pagination.
//

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import Compression
import PDFKit

enum EPUBBookletRenderer {

    /// The EPUB paginated onto portrait pages, spine order, ready for
    /// imposition. Runs on the main thread (HTML import requires it).
    static func pdfDocument(fromEPUBAt url: URL, pageSize: CGSize = CGSize(width: 595, height: 842)) -> PDFDocument? {
        guard let folder = extractZip(at: url) else { return nil }
        defer { try? FileManager.default.removeItem(at: folder) }

        guard let chapterURLs = spineChapterURLs(inExtractedEPUB: folder), !chapterURLs.isEmpty else { return nil }

        let text = NSMutableAttributedString()
        for chapterURL in chapterURLs {
            guard let chapter = try? NSAttributedString(
                url: chapterURL,
                options: [.documentType: NSAttributedString.DocumentType.html],
                documentAttributes: nil
            ) else { continue }
            if text.length > 0 {
                text.append(NSAttributedString(string: "\n\n"))
            }
            text.append(chapter)
        }
        guard text.length > 0 else { return nil }

        return paginatedPDF(from: text, pageSize: pageSize)
    }

    // MARK: Pagination

    /// The attributed string flowed into fixed pages with TextKit and
    /// drawn into a PDF context, one text container per page.
    private static func paginatedPDF(from attributed: NSAttributedString, pageSize: CGSize) -> PDFDocument? {
        let margin: CGFloat = 56
        let textArea = CGSize(width: pageSize.width - margin * 2, height: pageSize.height - margin * 2)

        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)

        var containers: [NSTextContainer] = []
        repeat {
            let container = NSTextContainer(size: textArea)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            containers.append(container)
            layoutManager.ensureLayout(for: container)
        } while layoutManager.glyphRange(for: containers[containers.count - 1]).upperBound < layoutManager.numberOfGlyphs

        var mediaBox = CGRect(origin: .zero, size: pageSize)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        for container in containers {
            context.beginPDFPage(nil)
            // TextKit draws top-down; flip the PDF page to match.
            context.saveGState()
            context.translateBy(x: 0, y: pageSize.height)
            context.scaleBy(x: 1, y: -1)
#if canImport(AppKit)
            let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphicsContext
#else
            UIGraphicsPushContext(context)
#endif
            let glyphRange = layoutManager.glyphRange(for: container)
            let origin = CGPoint(x: margin, y: margin)
            layoutManager.drawBackground(forGlyphRange: glyphRange, at: origin)
            layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: origin)
#if canImport(AppKit)
            NSGraphicsContext.restoreGraphicsState()
#else
            UIGraphicsPopContext()
#endif
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()

        return PDFDocument(data: data as Data)
    }

    // MARK: EPUB structure

    /// The spine's XHTML chapters, in reading order, as file URLs inside
    /// the extracted folder — via META-INF/container.xml and the OPF.
    /// The container is searched for rather than assumed at the top level,
    /// since zips made by zipping a folder carry the EPUB one level down.
    private static func spineChapterURLs(inExtractedEPUB folder: URL) -> [URL]? {
        guard let containerURL = containerXMLURL(under: folder),
              let containerXML = try? XMLDocument(contentsOf: containerURL),
              let rootfile = try? containerXML.nodes(forXPath: "//*[local-name()='rootfile']").first as? XMLElement,
              let opfPath = rootfile.attribute(forName: "full-path")?.stringValue else { return nil }

        // full-path is relative to the EPUB root: META-INF's parent.
        let epubRoot = containerURL.deletingLastPathComponent().deletingLastPathComponent()
        let opfURL = epubRoot.appendingPathComponent(opfPath)
        let opfFolder = opfURL.deletingLastPathComponent()
        guard let opf = try? XMLDocument(contentsOf: opfURL) else { return nil }

        var hrefByID: [String: String] = [:]
        for case let item as XMLElement in (try? opf.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']")) ?? [] {
            guard let id = item.attribute(forName: "id")?.stringValue,
                  let href = item.attribute(forName: "href")?.stringValue else { continue }
            let mediaType = item.attribute(forName: "media-type")?.stringValue ?? ""
            if mediaType.contains("xhtml") || mediaType.contains("html") {
                hrefByID[id] = href
            }
        }

        var chapters: [URL] = []
        for case let itemref as XMLElement in (try? opf.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']")) ?? [] {
            guard let idref = itemref.attribute(forName: "idref")?.stringValue,
                  let href = hrefByID[idref],
                  let decoded = href.removingPercentEncoding else { continue }
            chapters.append(opfFolder.appendingPathComponent(decoded))
        }
        return chapters
    }

    /// META-INF/container.xml wherever it sits in the extracted tree,
    /// shallowest match first.
    private static func containerXMLURL(under folder: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        var matches: [URL] = []
        while let candidate = enumerator?.nextObject() as? URL {
            if candidate.lastPathComponent == "container.xml",
               candidate.deletingLastPathComponent().lastPathComponent == "META-INF" {
                matches.append(candidate)
            }
        }
        return matches.min { $0.pathComponents.count < $1.pathComponents.count }
    }

    // MARK: Minimal zip reader

    /// Extracts every entry of the zip into a fresh temporary folder.
    /// Handles the two methods EPUBs use — stored and deflate — and
    /// reads sizes from the central directory, so entries written with
    /// streaming data descriptors extract correctly too.
    private static func extractZip(at url: URL) -> URL? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let bytes = [UInt8](data)

        func le16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        func le32(_ offset: Int) -> Int {
            Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }

        // End-of-central-directory record: scan back over the comment.
        var eocd = -1
        var scan = bytes.count - 22
        let scanFloor = max(0, bytes.count - 22 - 65535)
        while scan >= scanFloor {
            if bytes[scan] == 0x50, bytes[scan + 1] == 0x4B, bytes[scan + 2] == 0x05, bytes[scan + 3] == 0x06 {
                eocd = scan
                break
            }
            scan -= 1
        }
        guard eocd >= 0 else { return nil }
        let entryCount = le16(eocd + 10)
        var cursor = le32(eocd + 16)

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookletEPUB-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }

        for _ in 0..<entryCount {
            guard cursor + 46 <= bytes.count, le32(cursor) == 0x02014b50 else { return nil }
            let method = le16(cursor + 10)
            let compressedSize = le32(cursor + 20)
            let uncompressedSize = le32(cursor + 24)
            let nameLength = le16(cursor + 28)
            let extraLength = le16(cursor + 30)
            let commentLength = le16(cursor + 32)
            let localOffset = le32(cursor + 42)
            let name = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
            cursor += 46 + nameLength + extraLength + commentLength

            // Local header gives the true start of the entry's bytes.
            guard localOffset + 30 <= bytes.count, le32(localOffset) == 0x04034b50 else { return nil }
            let dataStart = localOffset + 30 + le16(localOffset + 26) + le16(localOffset + 28)
            guard dataStart + compressedSize <= bytes.count, !name.contains("..") else { return nil }

            let destination = folder.appendingPathComponent(name)
            if name.hasSuffix("/") {
                try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                continue
            }
            try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)

            let compressed = Data(bytes[dataStart..<(dataStart + compressedSize)])
            let contents: Data?
            switch method {
            case 0:
                contents = compressed
            case 8:
                contents = inflate(compressed, uncompressedSize: uncompressedSize)
            default:
                contents = nil
            }
            guard let contents else { return nil }
            guard (try? contents.write(to: destination)) != nil else { return nil }
        }
        return folder
    }

    /// Raw DEFLATE (zip method 8) — what Compression's ZLIB mode decodes.
    private static func inflate(_ compressed: Data, uncompressedSize: Int) -> Data? {
        guard uncompressedSize > 0 else { return Data() }
        var output = Data(count: uncompressedSize)
        let written = output.withUnsafeMutableBytes { outputBuffer in
            compressed.withUnsafeBytes { inputBuffer in
                compression_decode_buffer(
                    outputBuffer.bindMemory(to: UInt8.self).baseAddress!, uncompressedSize,
                    inputBuffer.bindMemory(to: UInt8.self).baseAddress!, compressed.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == uncompressedSize else { return nil }
        return output
    }
}
