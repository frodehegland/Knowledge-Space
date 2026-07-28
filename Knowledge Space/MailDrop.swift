import Foundation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

// Email into the library: drag a message from Apple Mail (or an .eml
// file from anywhere) onto the Knowledge Space window or its Dock
// icon, and it becomes a document — the sender its author, the
// recipients under "For the attention of", the words its body, and a
// message:// link that opens the original back in Mail. The kind is
// `external`: text from outside the community, exactly what the
// vocabulary made it for.

// MARK: - The message, parsed

/// A pragmatic RFC 822 reading of an .eml: the headers that matter,
/// and the plainest text the body offers. Not a full MIME library —
/// common single-part and multipart messages with quoted-printable or
/// base64 encodings, which is what Mail actually hands over.
nonisolated struct EmailMessage {
    var subject = ""
    var fromName: String?
    var fromEmail: String?
    var toNames: [String] = []
    var date: Date?
    var messageID: String?
    var body = ""

    static func parse(_ data: Data) -> EmailMessage? {
        guard let raw = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else { return nil }
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let headerEnd = text.range(of: "\n\n") ?? text.endIndex..<text.endIndex
        let headers = Self.headers(in: String(text[..<headerEnd.lowerBound]))
        guard !headers.isEmpty else { return nil }

        var message = EmailMessage()
        message.subject = decodeEncodedWords(headers["subject"] ?? "")
        if let from = headers["from"], let sender = mailboxes(in: from).first {
            message.fromName = sender.name
            message.fromEmail = sender.email
        }
        if let to = headers["to"] {
            message.toNames = mailboxes(in: to).map { $0.name ?? $0.email }
        }
        message.date = headers["date"].flatMap(parseDate)
        if let id = headers["message-id"] {
            message.messageID = id.trimmingCharacters(
                in: CharacterSet(charactersIn: "<> \t"))
        }
        if headerEnd.lowerBound < text.endIndex {
            let body = String(text[headerEnd.upperBound...])
            message.body = plainText(body: body, headers: headers)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A message with neither words nor a subject is not a message.
        guard !message.subject.isEmpty || !message.body.isEmpty else { return nil }
        return message
    }

    /// The Mail link that opens this message in place.
    var mailURL: URL? {
        guard let messageID, !messageID.isEmpty else { return nil }
        return URL(string: "message://%3C\(messageID)%3E")
    }

    // MARK: Headers

    /// Header lines, unfolded (a line starting with whitespace
    /// continues the one above), keys lowercased.
    private static func headers(in block: String) -> [String: String] {
        var headers: [String: String] = [:]
        var currentKey: String?
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.first == " " || line.first == "\t" {
                if let key = currentKey {
                    headers[key, default: ""] += " "
                        + line.trimmingCharacters(in: .whitespaces)
                }
            } else if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].lowercased()
                    .trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, !key.contains(" ") else { continue }
                currentKey = key
                headers[key] = String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return headers
    }

    /// "Name <addr>, \"Last, First\" <addr2>" → the mailboxes, commas
    /// inside quotes and angle brackets honored.
    static func mailboxes(in value: String) -> [(name: String?, email: String)] {
        var pieces: [String] = []
        var current = ""
        var inQuotes = false
        var inAngles = false
        for character in value {
            switch character {
            case "\"": inQuotes.toggle(); current.append(character)
            case "<" where !inQuotes: inAngles = true; current.append(character)
            case ">" where !inQuotes: inAngles = false; current.append(character)
            case "," where !inQuotes && !inAngles:
                pieces.append(current); current = ""
            default: current.append(character)
            }
        }
        pieces.append(current)
        return pieces.compactMap { piece in
            let trimmed = decodeEncodedWords(piece.trimmingCharacters(in: .whitespaces))
            guard !trimmed.isEmpty else { return nil }
            if let open = trimmed.firstIndex(of: "<"),
               let close = trimmed.firstIndex(of: ">"), open < close {
                let email = String(trimmed[trimmed.index(after: open)..<close])
                var name: String? = String(trimmed[..<open])
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \t\""))
                if name?.isEmpty == true { name = nil }
                return (name, email)
            }
            return (nil, trimmed)
        }
    }

    /// RFC 2047 encoded-words: "=?utf-8?Q?…?=" and the B (base64) form.
    static func decodeEncodedWords(_ text: String) -> String {
        var result = text
        let pattern = /=\?([^?]+)\?([bBqQ])\?([^?]*)\?=/
        while let match = result.firstMatch(of: pattern) {
            let charset = String(match.1).lowercased()
            let encoding: String.Encoding = charset.contains("utf") ? .utf8 : .isoLatin1
            var decoded = ""
            if match.2.lowercased() == "b" {
                if let data = Data(base64Encoded: String(match.3)),
                   let text = String(data: data, encoding: encoding) {
                    decoded = text
                }
            } else {
                let qp = String(match.3).replacingOccurrences(of: "_", with: " ")
                decoded = decodeQuotedPrintable(qp, encoding: encoding)
            }
            result.replaceSubrange(match.range, with: decoded)
        }
        return result
    }

    private static func decodeQuotedPrintable(_ text: String,
                                              encoding: String.Encoding) -> String {
        var bytes = Data()
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "=", let next = text.index(index, offsetBy: 3,
                                                       limitedBy: text.endIndex) {
                let hex = text[text.index(after: index)..<next]
                if hex == "\n" || hex.hasPrefix("\n") {
                    // Soft line break.
                    index = text.index(index, offsetBy: 2)
                    continue
                }
                if let byte = UInt8(hex, radix: 16) {
                    bytes.append(byte)
                    index = next
                    continue
                }
            }
            bytes.append(contentsOf: Array(String(character).utf8))
            index = text.index(after: index)
        }
        return String(data: bytes, encoding: encoding)
            ?? String(data: bytes, encoding: .isoLatin1) ?? text
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // Strip a trailing "(CEST)" style comment.
        let cleaned = value.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#,
                                                 with: "", options: .regularExpression)
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z",
                       "EEE, d MMM yyyy HH:mm Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: cleaned) { return date }
        }
        return nil
    }

    // MARK: Body

    /// The plainest text the body offers: the text/plain part of a
    /// multipart message, a tag-stripped reading of an HTML-only one,
    /// transfer encodings undone.
    private static func plainText(body: String, headers: [String: String],
                                  depth: Int = 0) -> String {
        let contentType = headers["content-type"] ?? "text/plain"
        if depth < 3, let boundary = parameter("boundary", in: contentType) {
            var htmlFallback: String?
            for part in body.components(separatedBy: "--" + boundary) {
                let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed != "--" else { continue }
                let normalized = trimmed.replacingOccurrences(of: "\r\n", with: "\n")
                let headerEnd = normalized.range(of: "\n\n")
                    ?? normalized.startIndex..<normalized.startIndex
                let partHeaders = Self.headers(in: String(normalized[..<headerEnd.lowerBound]))
                let partBody = headerEnd.upperBound < normalized.endIndex
                    ? String(normalized[headerEnd.upperBound...]) : ""
                let partType = (partHeaders["content-type"] ?? "text/plain").lowercased()
                if partType.hasPrefix("multipart") {
                    let inner = plainText(body: partBody, headers: partHeaders,
                                          depth: depth + 1)
                    if !inner.isEmpty { return inner }
                } else if partType.hasPrefix("text/plain") {
                    return decodeTransfer(partBody, headers: partHeaders)
                } else if partType.hasPrefix("text/html"), htmlFallback == nil {
                    htmlFallback = stripHTML(decodeTransfer(partBody, headers: partHeaders))
                }
            }
            return htmlFallback ?? ""
        }
        let decoded = decodeTransfer(body, headers: headers)
        return contentType.lowercased().hasPrefix("text/html")
            ? stripHTML(decoded) : decoded
    }

    private static func parameter(_ name: String, in contentType: String) -> String? {
        guard let range = contentType.range(of: name + #"\s*=\s*"#,
                                            options: [.regularExpression, .caseInsensitive])
        else { return nil }
        var rest = contentType[range.upperBound...]
        if rest.first == "\"" {
            rest = rest.dropFirst()
            return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
        }
        return String(rest.prefix { $0 != ";" && !$0.isWhitespace })
    }

    private static func decodeTransfer(_ text: String,
                                       headers: [String: String]) -> String {
        let charset = (parameter("charset", in: headers["content-type"] ?? "")
            ?? "utf-8").lowercased()
        let encoding: String.Encoding = charset.contains("utf") ? .utf8 : .isoLatin1
        switch (headers["content-transfer-encoding"] ?? "").lowercased() {
        case "base64":
            let stripped = text.filter { !$0.isWhitespace }
            guard let data = Data(base64Encoded: stripped),
                  let decoded = String(data: data, encoding: encoding)
                    ?? String(data: data, encoding: .isoLatin1) else { return text }
            return decoded
        case "quoted-printable":
            return decodeQuotedPrintable(text, encoding: encoding)
        default:
            return text
        }
    }

    /// A reading of HTML, not a rendering: styles and scripts dropped,
    /// tags removed, the commonest entities restored.
    private static func stripHTML(_ html: String) -> String {
        var text = html
        for block in ["style", "script", "head"] {
            text = text.replacingOccurrences(
                of: "<\(block)[^>]*>.*?</\(block)>", with: "",
                options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<br[^>]*>", with: "\n",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</p>", with: "\n\n",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "",
                                         options: .regularExpression)
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"),
            ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
        ]
        for (entity, plain) in entities {
            text = text.replacingOccurrences(of: entity, with: plain)
        }
        return text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n",
                                         options: .regularExpression)
    }
}

// MARK: - The drop, on AppState

extension AppState {

    /// What the window and Dock accept: Mail's own message types, and
    /// .eml files from anywhere.
    static var emailDropTypes: [UTType] {
        var types: [UTType] = [.fileURL]
        for identifier in ["com.apple.mail.email", "public.email-message"] {
            if let type = UTType(identifier) { types.append(type) }
        }
        return types
    }

    #if os(macOS)
    /// Providers from a drop on the window: Mail messages read
    /// directly, .eml files read from disk. Returns whether anything
    /// here speaks email.
    func handleEmailProviders(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            let mailType = ["com.apple.mail.email", "public.email-message"]
                .first { provider.hasItemConformingToTypeIdentifier($0) }
            if let mailType {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: mailType) { data, _ in
                    guard let data, let message = EmailMessage.parse(data) else { return }
                    Task { @MainActor in self.adoptEmail(message) }
                }
                continue
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier,
                                  options: nil) { item, _ in
                    var url: URL?
                    if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else if let direct = item as? URL {
                        url = direct
                    }
                    guard let url, url.pathExtension.lowercased() == "eml",
                          let data = try? Data(contentsOf: url),
                          let message = EmailMessage.parse(data) else { return }
                    Task { @MainActor in self.adoptEmail(message) }
                }
            }
        }
        return handled
    }

    /// .eml files handed to the app itself — the Dock icon, or Finder's
    /// Open With.
    func handleEmailFiles(_ urls: [URL]) {
        for url in urls where url.pathExtension.lowercased() == "eml" {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url),
                  let message = EmailMessage.parse(data) else { continue }
            adoptEmail(message)
        }
    }
    #endif

    /// One email as a document: the sender its author, the recipients
    /// its attention, the words its body, the way back a message://
    /// link — and everyone named becomes known to People.
    func adoptEmail(_ message: EmailMessage) {
        guard let folderURL = index.folderURL else {
            showNote("Choose a library folder first.")
            return
        }
        let created = Date.now
        let id = LiquidAddress.makeID(author: authorName, created: created) {
            self.index.isIDTaken($0)
        }
        let sender = message.fromName ?? message.fromEmail ?? "Unknown Sender"
        var paragraphs = LiquidDoc.parseBody(
            from: String(message.body.prefix(12000)))
        var next = paragraphs.count
        func add(_ text: String) {
            next += 1
            paragraphs.append(LiquidDoc.Paragraph(id: "e\(next)", heading: nil, text: text))
        }
        let sent = message.date.map {
            $0.formatted(date: .abbreviated, time: .shortened)
        } ?? "date unknown"
        add("Email from \(sender)"
            + (message.toNames.isEmpty ? "" : " to \(message.toNames.joined(separator: ", "))")
            + ", \(sent).")
        if let mail = message.mailURL {
            // The way back, machine-readable: Open in Mail parses this.
            add("Email: \(mail.absoluteString)")
        }
        var doc = LiquidDoc(format: LiquidDoc.knownFormat,
                            id: id,
                            title: message.subject.isEmpty
                                ? "Email from \(sender)" : message.subject,
                            author: sender,
                            created: created,
                            body: paragraphs,
                            links: [],
                            wraps: nil,
                            attention: message.toNames,
                            fileURL: folderURL.appendingPathComponent(id)
                                .appendingPathExtension(LiquidDoc.fileExtension))
        doc.documentType = LiquidDoc.DocumentType.external.rawValue
        if let sent = message.date {
            let parts = Calendar.current.dateComponents([.year, .month, .day], from: sent)
            if let year = parts.year {
                doc.date = LiquidDate(year: year, month: parts.month, day: parts.day)
            }
        }
        guard (try? doc.jsonData().write(to: doc.fileURL, options: .atomic)) != nil else {
            showNote("Could not write the email's note.")
            return
        }
        // Sender and recipients become people the system knows.
        ensureSpeakersKnown([sender] + message.toNames)
        index.rescan()
        selectedDocID = id
        showNote("“\(doc.title)” — the email stands as a document, linked back to Mail.")
    }
}
