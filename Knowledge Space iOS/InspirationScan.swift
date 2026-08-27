import SwiftUI
import UIKit
import Vision
import FoundationModels
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os

private let scanLog = Logger(subsystem: "com.origami.notes", category: "scan")

// Inspiration, scanned: the camera opens on a page, a poster, a
// whiteboard — and the capture decides what it holds. Read on-device
// first (Vision's OCR): primarily text goes looking for its book on
// Google Books — found, it becomes a quote citing a proper source with
// BibTeX, exactly as quotes work on the Mac. Not found, the on-device
// model may offer a clearly-labeled guess, and the words are kept
// regardless — they may be handwriting, or someone else's notes.
// Primarily an image, the photo itself is the point. Either way the
// photograph is kept beside the note in the shared folder, downsized,
// named by the note's id.

// MARK: - The camera

#if !os(visionOS)
/// The system camera, one photo, handed back as UIImage.
/// visionOS has no UIImagePickerController camera source; the Inspiration
/// feature is iOS/iPadOS-only.
struct CameraCapture: UIViewControllerRepresentable {
    let onPhoto: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPhoto: onPhoto) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate,
                             UINavigationControllerDelegate {
        let onPhoto: (UIImage?) -> Void
        init(onPhoto: @escaping (UIImage?) -> Void) { self.onPhoto = onPhoto }

        // The cover is SwiftUI's to dismiss — via the `scanning` flag
        // the callback lowers. Dismissing the picker here as well walks
        // up and takes the whole New Note sheet down with it.
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onPhoto(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onPhoto(nil)
        }
    }
}
#endif

// MARK: - The reading

nonisolated enum InspirationScanner {

    struct Reading {
        let text: String
        /// Primarily text (a page, a slide) rather than a picture: the
        /// OCR found a real passage, not a caption's worth of letters.
        var isTextFirst: Bool {
            text.split(whereSeparator: \.isWhitespace).count >= 12
        }
    }

    /// The photo's words, read on-device.
    static func read(_ image: UIImage) async -> Reading {
        guard let cgImage = image.cgImage else { return Reading(text: "") }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage,
                                            orientation: orientation(of: image))
        try? handler.perform([request])
        let lines = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
        return Reading(text: lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func orientation(of image: UIImage) -> CGImagePropertyOrientation {
        switch image.imageOrientation {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }

    // MARK: Google Books

    struct BookMatch {
        var title: String
        var authors: [String]
        var publisher: String?
        var year: String?
        var isbn: String?

        /// A stable citation key: first author's family name + year,
        /// the shelf's usual shape.
        var key: String {
            let family = authors.first?.split(separator: " ").last.map(String.init) ?? "unknown"
            return (family + (year ?? "")).lowercased()
                .filter { $0.isLetter || $0.isNumber }
        }

        var bibtex: String {
            var fields = ["  title = {\(title)}"]
            if !authors.isEmpty {
                fields.append("  author = {\(authors.joined(separator: " and "))}")
            }
            if let publisher { fields.append("  publisher = {\(publisher)}") }
            if let year { fields.append("  year = {\(year)}") }
            if let isbn { fields.append("  isbn = {\(isbn)}") }
            return "@book{\(key),\n" + fields.joined(separator: ",\n") + "\n}"
        }
    }

    /// Whether this scan belongs to a book, asked of Google Books in a
    /// few forms — a page's words, or a cover's title and author. Text
    /// is cleaned first (hyphenated line-breaks joined, page numbers and
    /// running headers dropped); then an unquoted full-text search (far
    /// more forgiving than an exact phrase, and right for covers), and
    /// only failing that the exact phrase. The first volume with a
    /// title answers; none means the passage is on its own.
    private enum SearchOutcome {
        case found(BookMatch)
        case empty                 // the API answered, nothing matched
        case throttled             // HTTP 429 — backed off and still refused
        case forbidden(Int)        // HTTP 401/403 — the key is not permitted
        case failed(Int)           // other HTTP or network trouble

        /// A plain sentence for the No Source panel.
        var reason: String? {
            switch self {
            case .found, .empty: return nil
            case .throttled:
                return "Google Books is rate-limiting the app (HTTP 429). It should recover shortly."
            case .forbidden(let code):
                return "Google Books refused the app's key (HTTP \(code)) — the key is not permitted for the Books API."
            case .failed(let code):
                return code == 0 ? "Could not reach Google Books (no network)."
                    : "Google Books returned an unexpected error (HTTP \(code))."
            }
        }
    }

    /// A found book, or the reason none was: the diagnostic is what the
    /// No Source panel shows so a refusal reads as a refusal, not a
    /// blank "nothing matched".
    static func findBook(for rawText: String) async -> (match: BookMatch?, reason: String?) {
        let text = cleanedForSearch(rawText)
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 3 else {
            return (nil, "Too few words were read to search on.")
        }
        // The queries, most-likely first: the opening (a cover's title
        // and author, or a page's first line), then a longer span. Kept
        // to two — the keyless API throttles hard, so each request is
        // spent carefully and only when the last answered cleanly.
        let queries = [
            words.prefix(10).joined(separator: " "),
            words.prefix(20).joined(separator: " "),
        ]
        var lastReason: String?
        for query in queries {
            let outcome = await search(query)
            switch outcome {
            case .found(let match): return (match, nil)
            case .empty:
                lastReason = "Google Books found nothing matching the scanned words."
                continue                       // try the next wording
            case .throttled, .forbidden, .failed:
                return (nil, outcome.reason)   // a real error — say it, stop
            }
        }
        return (nil, lastReason)
    }

    /// The Google Books API key, supplied the Author way: fetched from
    /// the encrypted key blob on GitHub and decrypted in-app, so it is
    /// never in the binary or source and can be rotated without an app
    /// update (see AIKeyProvider). A Gemini key is a Google API key, so
    /// the same one authorises Books where that project has the Books
    /// API enabled; a dedicated "books" entry is preferred when present.
    /// Absent, the lookup falls back to the keyless quota with backoff.
    static var apiKey: String {
        (AIKeyProvider.shared.key(for: "books")
         ?? AIKeyProvider.shared.key(for: "gemini") ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// One Google Books query, patient with the rate limit: a 429 is
    /// retried with growing backoff (1s, 2s, 4s) rather than taken as
    /// "no book". The `country` parameter is required — the API returns
    /// empty without it — and the key, when set, lifts the throttle.
    private static func search(_ query: String) async -> SearchOutcome {
        guard let encoded = query.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed)
        else { return .failed(0) }
        var string = "https://www.googleapis.com/books/v1/volumes?q=\(encoded)&country=US&maxResults=5"
        if !apiKey.isEmpty { string += "&key=\(apiKey)" }
        guard let url = URL(string: string) else { return .failed(0) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        var lastStatus = 0
        for attempt in 0..<4 {
            if attempt > 0 {
                // 1s, then 2s, then 4s — let the transient window pass.
                try? await Task.sleep(for: .seconds(pow(2.0, Double(attempt - 1))))
            }
            guard let (data, response) = try? await URLSession.shared.data(for: request) else {
                scanLog.info("Google Books: request failed for “\(query)”")
                return .failed(0)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            lastStatus = status
            // 429 (rate limit) and 5xx (transient server errors) are
            // worth waiting out — Google Books returns 503 under load.
            if status == 429 || (500...599).contains(status) {
                scanLog.info("Google Books: \(status), attempt \(attempt + 1) for “\(query)”")
                continue
            }
            if status == 401 || status == 403 {
                scanLog.info("Google Books: forbidden (\(status)) for “\(query)”")
                return .forbidden(status)
            }
            guard status == 200,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                scanLog.info("Google Books: status \(status) for “\(query)”")
                return .failed(status)
            }
            guard let items = object["items"] as? [[String: Any]], !items.isEmpty else {
                scanLog.info("Google Books: 0 results for “\(query)”")
                return .empty
            }
            scanLog.info("Google Books: \(items.count) result(s) for “\(query)”")
            // Not the first result blindly — the one whose title and
            // author words most overlap the scanned text, so a review
            // blurb doesn't get mislabelled as the magazine that ran it.
            let scanWords = Set(query.lowercased()
                .split(whereSeparator: { !$0.isLetter })
                .map(String.init).filter { $0.count > 3 })
            var best: (match: BookMatch, score: Int)?
            for item in items {
                guard let info = item["volumeInfo"] as? [String: Any],
                      let title = info["title"] as? String, !title.isEmpty else { continue }
                var match = BookMatch(title: title,
                                      authors: info["authors"] as? [String] ?? [])
                match.publisher = info["publisher"] as? String
                match.year = (info["publishedDate"] as? String)?.prefix(4).description
                if let identifiers = info["industryIdentifiers"] as? [[String: Any]] {
                    match.isbn = identifiers.first {
                        ($0["type"] as? String)?.hasPrefix("ISBN") == true
                    }?["identifier"] as? String
                }
                let hay = Set((title + " " + match.authors.joined(separator: " "))
                    .lowercased().split(whereSeparator: { !$0.isLetter })
                    .map(String.init))
                let score = scanWords.intersection(hay).count
                if best == nil || score > best!.score { best = (match, score) }
            }
            guard let best else { return .empty }
            scanLog.info("Google Books: best “\(best.match.title)” score \(best.score)")
            // A real overlap confirms the book; none means the scan
            // (often a blurb) doesn't name its book — better to say so
            // than to claim the first unrelated result.
            return best.score >= 1 ? .found(best.match) : .empty
        }
        // Ran out of attempts: 429 exhausted reads as throttled, a
        // stuck 5xx as a plain failure with its code.
        return lastStatus == 429 ? .throttled : .failed(lastStatus)
    }

    /// The OCR text made searchable: hyphenated line-breaks rejoined,
    /// lines that are only a page number dropped, an all-caps running
    /// header kept (it is often the title), whitespace collapsed.
    private static func cleanedForSearch(_ text: String) -> String {
        var joined = text.replacingOccurrences(
            of: #"(\w)-\n(\w)"#, with: "$1$2", options: .regularExpression)
        joined = joined.replacingOccurrences(of: "\n", with: " ")
        let words = joined.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "|•·—–")) }
            .filter { word in
                // A bare page number carries nothing for the search.
                !word.isEmpty && !(word.allSatisfy(\.isNumber) && word.count <= 4)
            }
        return words.joined(separator: " ")
    }

    // MARK: The model reads the scan first

    @Generable
    struct BookIdentification {
        @Guide(description: "True if this text is from or about a specific published book — a cover, a page, a back-cover blurb — rather than someone's own handwriting or notes")
        var isBook: Bool
        @Guide(description: "The book's exact title if you can tell it, otherwise empty")
        var title: String
        @Guide(description: "The book's author, family name and given name, if you can tell it, otherwise empty")
        var author: String
    }

    /// Apple Intelligence reads the OCR jumble — running headers, blurb,
    /// endorsements — and pulls out the title and author as fields.
    /// Nil when the on-device model is unavailable; the caller then
    /// falls back to a plain full-text search.
    static func identify(_ text: String) async -> BookIdentification? {
        let availability = SystemLanguageModel.default.availability
        guard availability == .available else {
            // The reason distinguishes "still downloading" (resolves
            // itself) from "device or region ineligible" (won't).
            switch availability {
            case .unavailable(.deviceNotEligible):
                scanLog.info("identify: model unavailable — device not eligible")
            case .unavailable(.appleIntelligenceNotEnabled):
                scanLog.info("identify: model unavailable — Apple Intelligence not enabled")
            case .unavailable(.modelNotReady):
                scanLog.info("identify: model unavailable — model not ready (downloading)")
            case .unavailable(let other):
                scanLog.info("identify: model unavailable — \(String(describing: other))")
            case .available:
                break
            }
            return nil
        }
        let session = LanguageModelSession()
        let opening = String(text.prefix(1500))
        guard let response = try? await session.respond(
            to: """
            This text was read by OCR from a photo — it may be a book \
            cover, a page, or a back-cover blurb, and may be noisy. \
            Identify the book it is from or about.

            \(opening)
            """,
            generating: BookIdentification.self) else {
            scanLog.info("identify: model returned nothing")
            return nil
        }
        let id = response.content
        scanLog.info("identify: isBook=\(id.isBook) title=“\(id.title)” author=“\(id.author)”")
        return id
    }

    /// A targeted Google Books lookup from the model's fields —
    /// `intitle:`/`inauthor:` is exact where a full-text guess is not,
    /// so it costs one precise request. Falls back to the fields
    /// themselves as the match when Google is throttled or silent, so
    /// the identification is kept either way.
    static func findBook(title: String, author: String) async -> BookMatch? {
        var terms: [String] = []
        if !title.isEmpty { terms.append("intitle:\(title)") }
        if !author.isEmpty { terms.append("inauthor:\(author)") }
        guard !terms.isEmpty else { return nil }
        switch await search(terms.joined(separator: "+")) {
        case .found(let match):
            return match
        case .empty, .throttled, .forbidden, .failed:
            // Google gave nothing, but the model's reading stands: the
            // title and author are worth keeping as the source.
            guard !title.isEmpty else { return nil }
            scanLog.info("findBook: keeping model's identification without Google")
            return BookMatch(title: title,
                             authors: author.isEmpty ? [] : [author])
        }
    }

    // MARK: The model's guess

    @Generable
    struct Recognition {
        @Guide(description: "Whether you recognize where this passage is from")
        var recognized: Bool
        @Guide(description: "Where the passage is from — work and author — in one sentence; empty if not recognized")
        var source: String
    }

    /// The on-device model's word on an unplaced passage — offered only
    /// when it claims recognition, and always written clearly labeled
    /// as its guess.
    static func guess(for text: String) async -> String? {
        guard SystemLanguageModel.default.availability == .available else { return nil }
        let session = LanguageModelSession()
        let opening = String(text.prefix(1200))
        guard let response = try? await session.respond(
            to: "Do you recognize where this passage is from?\n\n\(opening)",
            generating: Recognition.self) else { return nil }
        let reading = response.content
        let source = reading.source.trimmingCharacters(in: .whitespacesAndNewlines)
        return reading.recognized && !source.isEmpty ? source : nil
    }

    // MARK: The photograph

    /// The capture for the shared folder: orientation applied, longest
    /// side capped at 1280 (legible handwriting, light file), JPEG.
    static func photoData(from image: UIImage, maxSide: Int = 1280) -> Data? {
        guard let source = image.cgImage else { return nil }
        let scale = min(1, Double(maxSide) / Double(max(source.width, source.height)))
        let size = CGSize(width: Double(source.width) * scale,
                          height: Double(source.height) * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let upright = UIImage(cgImage: source, scale: image.scale,
                              orientation: image.imageOrientation)
        let drawn = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            upright.draw(in: CGRect(origin: .zero, size: size))
        }
        return drawn.jpegData(compressionQuality: 0.8)
    }
}

// MARK: - Adoption, on the model

/// What a scan turned out to hold, before anything is written: the
/// sheet shows it, the user decides.
struct ScanAnalysis {
    let image: UIImage
    let text: String
    let isTextFirst: Bool
    let book: InspirationScanner.BookMatch?
    let guess: String?
    /// Why no book, in plain words — shown in the No Source panel so a
    /// refusal or a rate-limit reads as itself, not a blank miss.
    var diagnostic: String? = nil
}

extension NotesModel {

    /// Reads the photo and looks for its source — nothing is written
    /// yet. The stage callback narrates for the progress indicator.
    func analyzeScan(_ image: UIImage,
                     stage: @MainActor @escaping (String) -> Void) async -> ScanAnalysis {
        scanLog.info("analyzeScan: begin")
        stage("Reading the photo…")
        let reading = await InspirationScanner.read(image)
        scanLog.info("analyzeScan: OCR read \(reading.text.count) chars, textFirst=\(reading.isTextFirst)")
        guard reading.isTextFirst else {
            return ScanAnalysis(image: image, text: reading.text,
                                isTextFirst: false, book: nil, guess: nil,
                                diagnostic: "The photo read as mostly image — \(reading.text.count) characters of text.")
        }
        var notes: [String] = ["Read \(reading.text.count) characters."]
        // Apple Intelligence reads the scan first, where it can: the
        // title and author it pulls out drive a precise lookup and are
        // kept regardless of what Google answers.
        stage("Reading with Apple Intelligence…")
        if let id = await InspirationScanner.identify(reading.text), id.isBook,
           !(id.title.isEmpty && id.author.isEmpty) {
            stage("Searching Google Books…")
            if let book = await InspirationScanner.findBook(title: id.title,
                                                            author: id.author) {
                scanLog.info("analyzeScan: book identified — \(book.title)")
                return ScanAnalysis(image: image, text: reading.text,
                                    isTextFirst: true, book: book, guess: nil)
            }
        } else {
            notes.append("Apple Intelligence did not read a book from it (its model may be off or still downloading).")
        }
        // No model, or it saw no book: a plain full-text search.
        stage("Searching Google Books…")
        let (book, reason) = await InspirationScanner.findBook(for: reading.text)
        if let book {
            scanLog.info("analyzeScan: book found by text — \(book.title)")
            return ScanAnalysis(image: image, text: reading.text,
                                isTextFirst: true, book: book, guess: nil)
        }
        if let reason { notes.append(reason) }
        scanLog.info("analyzeScan: no book; asking model for a guess")
        stage("Asking the on-device model…")
        let guess = await InspirationScanner.guess(for: reading.text)
        scanLog.info("analyzeScan: done, guess=\(guess ?? "nil")")
        return ScanAnalysis(image: image, text: reading.text,
                            isTextFirst: true, book: nil, guess: guess,
                            diagnostic: notes.joined(separator: " "))
    }

    /// The found-book path: the book joins the Library shelf as a
    /// source carrying its BibTeX — reused if already there — and the
    /// scan becomes an inspiration note citing it. A comment the reader
    /// typed is the note's own words; the photo travels along.
    func adoptScanAsSource(_ analysis: ScanAnalysis, comment: String) {
        guard let folderURL, let book = analysis.book else { return }
        let source = findOrCreateSource(for: book, in: folderURL)
        let citation = ([book.authors.joined(separator: ", "),
                         "“\(book.title)”", book.year ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")) + " [\(source.id)]"
        createInspirationCitingSource(comment: comment.trimmingCharacters(in: .whitespaces),
                                      on: source, citation: citation,
                                      title: book.title,
                                      image: analysis.image, in: folderURL)
    }

    /// The no-book path — Add as Image: the scan still becomes a
    /// source on the Library shelf (without BibTeX), carrying the
    /// read text and the model's labelled guess, so everything scanned
    /// gathers under Sources on the Mac. The photo travels along and an
    /// inspiration note cites it, keeping it visible on the phone.
    func adoptScanAsImage(_ analysis: ScanAnalysis, comment: String) {
        guard let folderURL else { return }
        let source = createScanSource(analysis, in: folderURL)
        createInspirationCitingSource(
            comment: comment.trimmingCharacters(in: .whitespaces),
            on: source, citation: "Scanned \(Date.now.formatted(date: .abbreviated, time: .shortened))",
            title: source.title, image: analysis.image, in: folderURL)
    }

    /// A plain source for a scan that matched no book: its title the
    /// first words read (or a dated fallback), its body the scanned
    /// text and any model guess. No BibTeX — it stands as a source all
    /// the same, on the Mac's shelf.
    private func createScanSource(_ analysis: ScanAnalysis,
                                  in folderURL: URL) -> LiquidDoc {
        let created = Date.now
        let id = LiquidAddress.makeID(author: authorName, created: created) { candidate in
            self.notes.contains { $0.id == candidate }
                || self.sources.contains { $0.id == candidate }
        }
        let words = analysis.text.split(whereSeparator: \.isWhitespace)
        let title = words.isEmpty
            ? "Scan \(created.formatted(date: .abbreviated, time: .shortened))"
            : words.prefix(6).joined(separator: " ")
        var body: [LiquidDoc.Paragraph] = []
        var next = 0
        func add(_ text: String) {
            next += 1
            body.append(LiquidDoc.Paragraph(id: "p\(next)", heading: nil, text: text))
        }
        if !analysis.text.isEmpty { add(analysis.text) }
        if let guess = analysis.guess {
            add("The on-device model's guess, unverified: \(guess)")
        }
        if body.isEmpty { add("A scanned image.") }
        var doc = LiquidDoc(format: LiquidDoc.knownFormat,
                            id: id,
                            title: title,
                            author: authorName,
                            created: created,
                            body: body,
                            links: [],
                            wraps: nil,
                            fileURL: folderURL.appendingPathComponent(id)
                                .appendingPathExtension(LiquidDoc.fileExtension))
        doc.documentType = LiquidDoc.DocumentType.source.rawValue
        try? doc.jsonData().write(to: doc.fileURL, options: .atomic)
        sources.append(doc)
        return doc
    }

    /// The source for a found book — reused when the shelf already
    /// holds it (by ISBN or citation key), created otherwise.
    private func findOrCreateSource(for book: InspirationScanner.BookMatch,
                                    in folderURL: URL) -> LiquidDoc {
        if let existing = sources.first(where: { doc in
            guard let bibtex = doc.references.first?.bibtex else { return false }
            if let isbn = book.isbn, bibtex.contains(isbn) { return true }
            return doc.references.first?.id.caseInsensitiveCompare(book.key) == .orderedSame
        }) {
            return existing
        }
        let created = Date.now
        let id = LiquidAddress.makeID(author: authorName, created: created) { candidate in
            self.notes.contains { $0.id == candidate }
                || self.sources.contains { $0.id == candidate }
        }
        let citation = [book.authors.joined(separator: ", "),
                        "“\(book.title)”",
                        book.publisher ?? "", book.year ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        var doc = LiquidDoc(format: LiquidDoc.knownFormat,
                            id: id,
                            title: book.title,
                            author: authorName,
                            created: created,
                            body: [LiquidDoc.Paragraph(id: "p1", heading: nil,
                                                       text: citation + " [\(id)]")],
                            links: [],
                            wraps: nil,
                            fileURL: folderURL.appendingPathComponent(id)
                                .appendingPathExtension(LiquidDoc.fileExtension))
        doc.documentType = LiquidDoc.DocumentType.source.rawValue
        doc.references = [LiquidDoc.Reference(id: book.key, bibtex: book.bibtex)]
        if let year = book.year.flatMap(Int.init) {
            doc.date = LiquidDate(year: year)
        }
        try? doc.jsonData().write(to: doc.fileURL, options: .atomic)
        sources.append(doc)
        return doc
    }

    /// An inspiration note that records a scanned source: its citation
    /// sentence, the reader's own comment where they gave one, and a
    /// `cites` link to the source on the shelf so the BibTeX (where
    /// there is one) is a hop away. The source is the content — no
    /// blurb dumped into the note.
    private func createInspirationCitingSource(comment: String,
                                               on source: LiquidDoc,
                                               citation: String,
                                               title: String,
                                               image: UIImage, in folderURL: URL) {
        let created = Date.now
        // The uniqueness check must see the source just minted (same
        // second, same author): without it the note took the source's
        // id and overwrote its file, leaving a note that cites itself.
        let id = LiquidAddress.makeID(author: authorName, created: created) { candidate in
            candidate == source.id
                || self.notes.contains { $0.id == candidate }
                || self.sources.contains { $0.id == candidate }
        }
        var body: [LiquidDoc.Paragraph] = []
        var next = 0
        func add(_ text: String) {
            next += 1
            body.append(LiquidDoc.Paragraph(id: "s\(next)", heading: nil, text: text))
        }
        if !comment.isEmpty { add(comment) }
        add(citation)
        if let photoName = writePhoto(image, noteID: id, in: folderURL) {
            add("Photo: \(photoName)")
        }
        var doc = LiquidDoc(format: LiquidDoc.knownFormat,
                            id: id,
                            title: title,
                            author: authorName,
                            created: created,
                            body: body,
                            links: [LiquidDoc.Link(to: source.id, fragment: nil,
                                                   rel: "cites",
                                                   bibtex: source.references.first?.bibtex)],
                            wraps: nil,
                            fileURL: folderURL.appendingPathComponent(id)
                                .appendingPathExtension(LiquidDoc.fileExtension))
        doc.documentType = LiquidDoc.DocumentType.inspiration.rawValue
        if let place = currentPlace { doc.location = place }
        try? doc.jsonData().write(to: doc.fileURL, options: .atomic)
        rescan()
    }

    /// The scan kept on its own terms: an inspiration note — the words
    private func writePhoto(_ image: UIImage, noteID: String,
                            in folderURL: URL) -> String? {
        guard let data = InspirationScanner.photoData(from: image) else { return nil }
        let name = "\(noteID).photo.jpg"
        guard (try? data.write(to: folderURL.appendingPathComponent(name),
                               options: .atomic)) != nil else { return nil }
        return name
    }
}
