import SwiftUI

/// A style wherever styles are shown: a picture and its name. Also the "+" tile that starts one.
struct StyleTile: View {
    let title: String
    /// Dashed, with a plus: the tile that makes a style.
    var isNew = false
    /// Changes when the picture should be made again.
    var version = ""
    /// The picture: the one a style was learned from, or a photo with the style tried on.
    var picture: (() async -> CGImage?)?
    @State private var image: CGImage?

    static let side: CGFloat = 84

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Color(white: isNew ? 0.09 : 0.13)
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill().transition(.opacity)
                } else {
                    Image(systemName: isNew ? "plus" : "camera.filters")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(isNew ? Color.accentColor : Color.secondary)
                }
            }
            .frame(width: StyleTile.side, height: StyleTile.side)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                if isNew {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color(white: 0.3), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                }
            }
            .animation(.easeOut(duration: 0.25), value: image != nil)
            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .frame(width: StyleTile.side)
        }
        .contentShape(Rectangle())
        .task(id: version) {
            guard let picture, let made = await picture() else { return }
            image = made
        }
    }
}

extension View {
    /// Asks for a style's name: when saving a look, and when renaming.
    func styleNameAlert(_ title: String, isPresented: Binding<Bool>, name: Binding<String>, save: @escaping () -> Void) -> some View {
        alert(title, isPresented: isPresented) {
            TextField(L10n.styleNamePlaceholder, text: name)
            Button(L10n.save, action: save)
            Button(L10n.cancel, role: .cancel) {}
        }
    }
}
