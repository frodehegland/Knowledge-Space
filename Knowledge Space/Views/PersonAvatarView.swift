import SwiftUI

/// A person's face wherever they appear. The cartoon portrait (or photo)
/// from the contact directory comes first, then the image their record
/// names in the community folder, then the photograph their identity
/// card names; failing all, initials in a rounded square. The interface
/// matches Origami Text's, so view modules travel between the apps
/// unchanged.
struct PersonAvatarView: View {
    @Environment(AppModel.self) private var model
    let name: String
    var size: CGFloat = 28

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
        ZStack {
            shape.fill(.quaternary)
            #if os(macOS)
            if let image = directoryImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let url = cardPhotoURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    initialsText
                }
            } else {
                initialsText
            }
            #else
            if let url = cardPhotoURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    initialsText
                }
            } else {
                initialsText
            }
            #endif
        }
        .frame(width: size, height: size)
        .clipShape(shape)
    }

    private var initialsText: some View {
        Text(initials)
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    #if os(macOS)
    /// The contact directory's image: the cartoon portrait drawn on this
    /// Mac, the photo awaiting one, or the image the record carries in
    /// the community folder from another machine.
    private var directoryImage: NSImage? {
        guard let person = model.people.person(named: name) else { return nil }
        // Portraits are keyed by localID — the one identifier that never
        // changes, even when an ORCID is adopted mid-edit.
        if let local = model.portraits.portrait(for: person.localID)
            ?? model.portraits.original(for: person.localID) {
            return local
        }
        if let file = person.portraitFile, let folder = model.index.folderURL {
            return model.portraits.communityImage(at: folder.appendingPathComponent(file))
        }
        return nil
    }
    #endif

    /// The photograph the person's identity card names, when their card
    /// is in the folder and carries one.
    private var cardPhotoURL: URL? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let cardDoc = model.cards.first(where: {
            $0.author.trimmingCharacters(in: .whitespaces)
                .caseInsensitiveCompare(trimmed) == .orderedSame
        }) else { return nil }
        return IdentityCard(doc: cardDoc).photoURL(in: model.index.folderURL)
    }

    private var initials: String {
        let words = name.split(separator: " ")
        let first = words.first?.first.map(String.init) ?? ""
        let last = words.count > 1 ? words.last?.first.map(String.init) ?? "" : ""
        let joined = (first + last).uppercased()
        return joined.isEmpty ? "?" : joined
    }
}
