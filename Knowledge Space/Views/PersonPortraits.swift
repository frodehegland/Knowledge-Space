#if os(macOS)
import SwiftUI
import AppKit
import CoreImage
import ImagePlayground
import Vision

// The portrait pipeline carried over from Digital Letters: the photo the
// user provides is kept untouched, and Image Playground draws the cartoon
// portrait shown everywhere, published into the shared folder so every
// machine shows the face with the name.

/// The cartoon style applied to contact photos, chosen once so every
/// person in the community is drawn in the same visual language.
enum PortraitStyle: String, CaseIterable, Identifiable {
    case animation
    case illustration
    case sketch

    var id: String { rawValue }

    var label: String {
        switch self {
        case .animation: "Animation — 3D cartoon"
        case .illustration: "Illustration — 2D cartoon"
        case .sketch: "Sketch — hand-drawn"
        }
    }

    var playgroundStyle: ImagePlaygroundStyle {
        switch self {
        case .animation: .animation
        case .illustration: .illustration
        case .sketch: .sketch
        }
    }

    static var current: PortraitStyle {
        PortraitStyle(rawValue: UserDefaults.standard.string(forKey: AppSettings.portraitStyleKey) ?? "")
            ?? .illustration
    }

    /// The one description every portrait is drawn from, so the whole
    /// community is framed the same way. An emptied setting falls back
    /// to the default.
    static let defaultConcept = "Headshot, professional portrait for publication of this academic person with a neutral grey background"

    static var concept: String {
        let stored = UserDefaults.standard.string(forKey: AppSettings.portraitPromptKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? defaultConcept : stored
    }
}

/// Portrait images for people: the photo the user provided, kept untouched,
/// and the cartoon portrait Image Playground drew from it. Both live as PNGs
/// in the app container, keyed by the person's localID — stable even as an
/// ORCID is adopted — so a style change can always re-draw every portrait
/// from its original.
@MainActor @Observable
final class PersonPortraitStore {
    /// People whose cartoon is being drawn right now.
    private(set) var generatingIDs: Set<String> = []
    /// The most recent generation failure per person, for the form to show.
    private(set) var errors: [String: String] = [:]
    /// Progress of a style change re-drawing every portrait.
    private(set) var isRestyling = false
    private(set) var restyleDone = 0
    private(set) var restyleTotal = 0

    /// Whether this Mac lets the app draw cartoons without UI. Some systems
    /// support Image Playground's sheet but refuse programmatic creation —
    /// there the form falls back to the system sheet, seeded with the photo.
    private(set) var supportsAutomaticGeneration = true

    /// Bumped whenever an image file changes; reading it inside the image
    /// accessors is what lets views refresh without observing the cache.
    private(set) var revision = 0
    @ObservationIgnored private var cache: [String: NSImage?] = [:]

    private let directory: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        directory = base.appendingPathComponent("PersonPortraits", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Task {
            do {
                _ = try await ImageCreator()
                supportsAutomaticGeneration = true
            } catch {
                supportsAutomaticGeneration = false
            }
        }
    }

    // MARK: - Reading

    /// The cartoon portrait, if one has been generated.
    func portrait(for personID: String) -> NSImage? {
        image(at: portraitURL(for: personID))
    }

    /// The untouched photo the user provided.
    func original(for personID: String) -> NSImage? {
        image(at: originalURL(for: personID))
    }

    func hasOriginal(for personID: String) -> Bool {
        _ = revision
        return FileManager.default.fileExists(atPath: originalURL(for: personID).path)
    }

    /// The photo as generation sees it: re-framed around the head with even
    /// margin, so every cartoon comes out with the same passport-photo
    /// framing no matter how the photo was shot. Falls back to the photo
    /// itself when no face is found.
    func framedOriginal(for personID: String) -> NSImage? {
        _ = revision
        let key = "framed-" + sanitized(personID)
        if let cached = cache[key] { return cached }
        var framed: NSImage?
        if let photo = original(for: personID)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil),
           let framedCG = Self.headshotFrame(photo) {
            framed = NSImage(cgImage: framedCG, size: .zero)
        }
        cache[key] = framed
        return framed
    }

    // MARK: - The pipeline

    /// Adopts a photo for the person: stores it untouched. Drawing the
    /// cartoon is a separate step — the form decides whether that happens
    /// instantly or on request.
    func adoptPhoto(_ photo: NSImage, for personID: String) {
        guard let data = pngData(from: photo) else {
            errors[personID] = "That image could not be read."
            return
        }
        try? data.write(to: originalURL(for: personID), options: .atomic)
        try? FileManager.default.removeItem(at: portraitURL(for: personID))
        invalidate(personID)
        // Warm the head-framed rendition so processing starts without a pause.
        _ = framedOriginal(for: personID)
    }

    /// Adopts a cartoon the user accepted in the system Image Playground
    /// sheet — the fallback path when automatic creation is refused.
    func adoptSheetPortrait(from url: URL, for personID: String) {
        guard let image = NSImage(contentsOf: url), let data = pngData(from: image) else {
            errors[personID] = "The generated image could not be read."
            return
        }
        try? data.write(to: portraitURL(for: personID), options: .atomic)
        try? FileManager.default.removeItem(at: url)
        errors[personID] = nil
        invalidate(personID)
    }

    /// Draws (or re-draws) the cartoon from the stored original. The photo
    /// itself is never altered, so this can run again after a style change.
    func generatePortrait(for personID: String) {
        guard !generatingIDs.contains(personID),
              let original = generationSource(for: personID) else { return }
        generatingIDs.insert(personID)
        errors[personID] = nil
        let style = PortraitStyle.current
        Task {
            do {
                let cartoon = try await Self.stylize(original, style: style.playgroundStyle,
                                                     concept: PortraitStyle.concept)
                try savePortrait(cartoon, for: personID)
            } catch ImageCreator.Error.notSupported {
                // This Mac refuses headless creation; the form offers the
                // system sheet instead, so this is not an error to show.
                supportsAutomaticGeneration = false
            } catch {
                errors[personID] = "Could not create the cartoon portrait: \(error.localizedDescription)"
            }
            generatingIDs.remove(personID)
            invalidate(personID)
        }
    }

    /// Forgets both images; the person shows as initials again.
    func removeImages(for personID: String) {
        try? FileManager.default.removeItem(at: originalURL(for: personID))
        try? FileManager.default.removeItem(at: portraitURL(for: personID))
        errors[personID] = nil
        invalidate(personID)
    }

    /// Re-draws every portrait from its stored original — the style setting
    /// changed, and consistency across the community is the point.
    func restyleAllPortraits() {
        guard !isRestyling, supportsAutomaticGeneration else { return }
        let ids = allOriginalIDs()
        guard !ids.isEmpty else { return }
        isRestyling = true
        restyleDone = 0
        restyleTotal = ids.count
        let style = PortraitStyle.current
        Task {
            for id in ids {
                if let original = generationSource(for: id) {
                    do {
                        let cartoon = try await Self.stylize(original, style: style.playgroundStyle,
                                                             concept: PortraitStyle.concept)
                        try savePortrait(cartoon, for: id)
                        errors[id] = nil
                    } catch {
                        errors[id] = "Could not create the cartoon portrait: \(error.localizedDescription)"
                    }
                }
                restyleDone += 1
                invalidate(id)
            }
            isRestyling = false
        }
    }

    /// The generated cartoon follows the composition of its source, so the
    /// head-with-margin framing is imposed on the photo before generation:
    /// find the face, crop a square around the head, pad with neutral grey.
    private static func headshotFrame(_ photo: CGImage) -> CGImage? {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: photo, options: [:])
        guard (try? handler.perform([request])) != nil,
              let faces = request.results, !faces.isEmpty else { return nil }
        // The largest face is the sitter; smaller ones are background.
        guard let face = faces.max(by: {
            $0.boundingBox.width * $0.boundingBox.height
                < $1.boundingBox.width * $1.boundingBox.height
        }) else { return nil }

        // Everything below works in CGContext coordinates (origin bottom
        // left), which is also how Vision reports its normalized box.
        let width = CGFloat(photo.width)
        let height = CGFloat(photo.height)
        let faceRect = CGRect(x: face.boundingBox.minX * width,
                              y: face.boundingBox.minY * height,
                              width: face.boundingBox.width * width,
                              height: face.boundingBox.height * height)
        // Vision's box covers eyebrows to chin; the head with hair sits
        // higher and needs air around it. 2.6× face height with the centre
        // lifted gives full head plus even margin.
        let side = faceRect.height * 2.6
        let center = CGPoint(x: faceRect.midX,
                             y: faceRect.midY + faceRect.height * 0.15)
        let crop = CGRect(x: center.x - side / 2,
                          y: center.y - side / 2,
                          width: side, height: side)

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil,
                                      width: Int(side.rounded()),
                                      height: Int(side.rounded()),
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Where the crop reaches past the photo, neutral grey continues the
        // backdrop the portrait prompt asks for.
        context.setFillColor(CGColor(gray: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.draw(photo, in: CGRect(x: -crop.minX, y: -crop.minY,
                                       width: width, height: height))
        return context.makeImage()
    }

    /// What generation starts from: the head-framed rendition when a face
    /// was found, else the photo as provided.
    private func generationSource(for personID: String) -> CGImage? {
        (framedOriginal(for: personID) ?? original(for: personID))?
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// One call to Image Playground: the photo as the basis, edit-existing
    /// so the result stays as close to the person as the model allows.
    private static func stylize(_ photo: CGImage, style: ImagePlaygroundStyle,
                                concept: String) async throws -> CGImage {
        let creator = try await ImageCreator()
        var options = ImagePlaygroundOptions()
        // creationStrategy arrived with macOS 27; earlier systems use the
        // automatic strategy, which still takes the photo as the basis.
        if #available(macOS 27.0, iOS 27.0, visionOS 27.0, *) {
            options.creationStrategy = .editExisting
        }
        let concepts: [ImagePlaygroundConcept] = [.image(photo), .text(concept)]
        for try await created in creator.images(for: concepts,
                                                style: style,
                                                options: options,
                                                limit: 1) {
            return created.cgImage
        }
        throw ImageCreator.Error.creationFailed
    }

    // MARK: - Community folder

    /// Copies the person's image (cartoon first, else the photo) into the
    /// community folder's Portraits directory, so the record's JSON can
    /// carry it to every machine. Returns the path relative to the folder,
    /// or nil when the person has no image at all.
    func publish(personID: String, into folder: URL) -> String? {
        let fm = FileManager.default
        let cartoon = portraitURL(for: personID)
        let source = fm.fileExists(atPath: cartoon.path) ? cartoon : originalURL(for: personID)
        guard fm.fileExists(atPath: source.path) else { return nil }
        let relative = "Portraits/\(sanitized(personID)).png"
        let destination = folder.appendingPathComponent(relative)
        let sourceDate = (try? source.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        let destinationDate = (try? destination.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        // Already current in the folder — nothing to write.
        if let destinationDate, destinationDate >= sourceDate { return relative }
        do {
            try fm.createDirectory(at: folder.appendingPathComponent("Portraits", isDirectory: true),
                                   withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: source, to: destination)
            cache[destination.lastPathComponent] = nil
            revision += 1
            return relative
        } catch {
            return nil
        }
    }

    /// An image a person's record refers to — a file in the community
    /// folder — read through the same cache as the local portraits.
    func communityImage(at url: URL) -> NSImage? {
        image(at: url)
    }

    // MARK: - Files

    private func originalURL(for personID: String) -> URL {
        directory.appendingPathComponent("\(sanitized(personID))-original.png")
    }

    private func portraitURL(for personID: String) -> URL {
        directory.appendingPathComponent("\(sanitized(personID))-portrait.png")
    }

    /// Person ids are ORCID iDs or UUID strings — already file-safe; this
    /// only guards against a stray separator.
    private func sanitized(_ id: String) -> String {
        id.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    private func allOriginalIDs() -> [String] {
        let suffix = "-original.png"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(suffix) }.map { String($0.dropLast(suffix.count)) }
    }

    private func image(at url: URL) -> NSImage? {
        _ = revision
        let key = url.lastPathComponent
        if let cached = cache[key] { return cached }
        let image = NSImage(contentsOf: url)
        cache[key] = image
        return image
    }

    private func invalidate(_ personID: String) {
        cache[originalURL(for: personID).lastPathComponent] = nil
        cache[portraitURL(for: personID).lastPathComponent] = nil
        cache["framed-" + sanitized(personID)] = nil
        revision += 1
    }

    private func savePortrait(_ cartoon: CGImage, for personID: String) throws {
        let rep = NSBitmapImageRep(cgImage: cartoon)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw ImageCreator.Error.creationFailed
        }
        try data.write(to: portraitURL(for: personID), options: .atomic)
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
#endif
