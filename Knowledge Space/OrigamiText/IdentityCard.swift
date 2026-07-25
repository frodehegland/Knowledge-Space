import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// A person's public identity as the community folder carries it: an
/// ordinary Origami document (`documentType: "card"`) whose body is
/// readable lines — "Given Name: Frode" — so the full record stays plain
/// text per the format's principles. Everything on the card is public;
/// it lives beside the notes and letters, and every app reading the
/// folder — Mac, phone, headset — reads the same record.
struct IdentityCard {
    static let documentType = "card"

    var personalTitle = ""
    var givenName = ""
    var middleName = ""
    var familyName = ""
    var orcid = ""
    var affiliation = ""
    /// The card's photograph: the name of an image file in the same
    /// shared folder, referenced by a readable "Photo:" line. The name
    /// is derived from the card's id — already unique and stable — so
    /// no separate identifier registry is needed.
    var photoFileName = ""

    /// The name as documents credit it — the card's title and author,
    /// and the author of every document its owner makes.
    var displayName: String {
        [givenName, middleName, familyName]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The card as its document's text: one readable line per field,
    /// empty fields omitted.
    var bodyText: String {
        var lines: [String] = []
        func add(_ label: String, _ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { lines.append("\(label): \(trimmed)") }
        }
        add("Personal Title", personalTitle)
        add("Given Name", givenName)
        add("Middle Name", middleName)
        add("Family Name", familyName)
        add("ORCID", orcid)
        add("Affiliation", affiliation)
        add("Photo", photoFileName)
        return lines.joined(separator: "\n")
    }

    /// The photo file the card names, in the given shared folder — nil
    /// when the card carries no photo or the name is not a plain
    /// filename.
    func photoURL(in folder: URL?) -> URL? {
        let name = photoFileName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/"), let folder else { return nil }
        return folder.appendingPathComponent(name)
    }

    /// The photo's filename for a card: the card's document id, which
    /// is already unique in the folder and stable for the card's life.
    static func photoFileName(forCardID id: String) -> String {
        "\(id).photo.jpg"
    }

    init() {}

    /// The card read back from its document, leniently — lines it does
    /// not recognize are left alone, per the format's tolerance. A card
    /// carrying no name lines falls back to splitting its author.
    init(doc: LiquidDoc) {
        for line in doc.bodyEditingText.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let label = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            switch label {
            case "personal title": personalTitle = value
            case "given name": givenName = value
            case "middle name": middleName = value
            case "family name": familyName = value
            case "orcid": orcid = value
            case "affiliation": affiliation = value
            case "photo": photoFileName = value
            default: break
            }
        }
        if displayName.isEmpty {
            var parts = doc.author.split(separator: " ").map(String.init)
            if !parts.isEmpty { givenName = parts.removeFirst() }
            if !parts.isEmpty { familyName = parts.removeLast() }
            middleName = parts.joined(separator: " ")
        }
    }
}

/// The card's photograph, processed for the shared folder: whatever the
/// user picked comes out as a small square JPEG — orientation applied,
/// center-cropped, capped at 512 pixels — so every card's photo travels
/// light and reads the same on every platform.
nonisolated enum CardPhoto {
    static let maxPixels = 512

    static func processed(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // The thumbnail path applies EXIF orientation and bounds the
        // longer side, so the crop below works in upright pixels.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels * 2
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let side = min(image.width, image.height, maxPixels)
        let scale = Double(side) / Double(min(image.width, image.height))
        guard let context = CGContext(data: nil, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        // Scaled so the short side fills the square; the long side's
        // overhang falls off both edges evenly — a center crop.
        let width = Double(image.width) * scale
        let height = Double(image.height) * scale
        context.draw(image, in: CGRect(x: (Double(side) - width) / 2,
                                       y: (Double(side) - height) / 2,
                                       width: width, height: height))
        guard let squared = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, squared, [
            kCGImageDestinationLossyCompressionQuality: 0.85
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}
