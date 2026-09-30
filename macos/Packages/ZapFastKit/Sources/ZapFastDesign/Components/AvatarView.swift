import SwiftUI

/// A round profile picture, or initials on a colour derived from the id
/// while there is none.
public struct AvatarView: View {
    public enum Placeholder: Sendable {
        case initials(String)
        case symbol(String)
    }

    private let url: URL?
    private let seed: String
    private let placeholder: Placeholder
    private let size: CGFloat
    /// Changes when the picture at `url` was replaced by a new one.
    private let version: Int

    @State private var image: NSImage?

    public init(url: URL?, seed: String, placeholder: Placeholder, size: CGFloat, version: Int = 0) {
        self.url = url
        self.seed = seed
        self.placeholder = placeholder
        self.size = size
        self.version = version
    }

    private struct Source: Equatable {
        var url: URL?
        var version: Int
    }

    public var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle().fill(Palette.sender(seed).gradient)
                placeholderContent
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
        .task(id: Source(url: url, version: version)) {
            guard let url else { image = nil; return }
            image = await Thumbnails.load(url, points: size)
        }
    }

    @ViewBuilder private var placeholderContent: some View {
        switch placeholder {
        case .initials(let text):
            Text(Self.initials(text))
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size * 0.42, weight: .medium))
        }
    }

    /// Up to two letters from the first words, skipping a leading `~`.
    public static func initials(_ name: String) -> String {
        let words = name
            .trimmingCharacters(in: CharacterSet(charactersIn: "~ "))
            .split(whereSeparator: \.isWhitespace)
            .filter { $0.first?.isLetter == true }
        let letters = words.prefix(2).compactMap(\.first).map(String.init)
        return letters.isEmpty ? "#" : letters.joined().uppercased()
    }
}

#Preview {
    HStack {
        AvatarView(url: nil, seed: "a", placeholder: .initials("Ada Lovelace"), size: 40)
        AvatarView(url: nil, seed: "b", placeholder: .symbol("person.2.fill"), size: 40)
    }
    .padding()
}
