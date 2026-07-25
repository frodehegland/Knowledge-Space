import SwiftUI

/// A person's face wherever they appear. When the shared folder holds
/// the person's identity card and the card names a photograph, that
/// photo is the face; otherwise initials in a rounded square. The
/// interface matches Origami Text's, so view modules travel between
/// the apps unchanged.
struct PersonAvatarView: View {
    @Environment(AppModel.self) private var model
    let name: String
    var size: CGFloat = 28

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
        ZStack {
            shape.fill(.quaternary)
            if let url = photoURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    initialsText
                }
            } else {
                initialsText
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
    }

    private var initialsText: some View {
        Text(initials)
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    /// The photograph the person's card names, when their card is in
    /// the folder and carries one.
    private var photoURL: URL? {
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
