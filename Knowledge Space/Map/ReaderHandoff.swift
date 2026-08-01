//
//  ReaderHandoff.swift
//  Knowledge Space
//
//  Handing an external file a node names off to another app on visionOS —
//  Reader above all. There is no NSWorkspace here: the seamless path is a
//  URL scheme the other app registers (`reader://open?path=…`), and the
//  reliable fallback when nothing answers is the system share sheet's
//  "Open in…". The scheme is a template the reader can edit in Settings,
//  so a change of scheme never needs a change of code.
//

#if os(visionOS)
import SwiftUI
import UIKit

/// A request to open a file outside Knowledge Space. A fresh id each time
/// lets the controls window act on the same file twice in a row.
struct ExternalOpenRequest: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}

enum ReaderHandoff {

    /// The scheme template's default: hand the file to Reader by path.
    static let defaultScheme = "reader://open?path=<file>"

    /// Builds the launch URL from the user's scheme template, replacing
    /// the tokens with the file's details. `<file>`/`<path>` carry the
    /// full path, `<name>` just the file name — each percent-encoded so a
    /// path with spaces survives. Returns `nil` when the filled template
    /// is not a URL, so the caller can fall back to the share sheet.
    static func schemeURL(forFileAt fileURL: URL, template: String) -> URL? {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // A query value must not carry the delimiters that separate one
        // query item from the next, or the path would be misread.
        let allowed = CharacterSet.urlQueryAllowed
            .subtracting(CharacterSet(charactersIn: "&=?#+/"))
        let path = fileURL.path
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        let name = fileURL.lastPathComponent
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name

        let filled = trimmed
            .replacingOccurrences(of: "<file>", with: encodedPath)
            .replacingOccurrences(of: "<path>", with: encodedPath)
            .replacingOccurrences(of: "<name>", with: encodedName)
        return URL(string: filled)
    }
}

/// The system "Open in…" / share sheet, used when no app answers the
/// Reader scheme so the file can still reach another reader.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
