import OscuruCore
import SwiftUI

/// A version of the photo opened full screen.
struct Viewed: Identifiable {
    let id = UUID()
    let state: EditingState
    /// The version before it, for comparing; nil for the original.
    let before: EditingState?
    let isCurrent: Bool
}

/// One version, filling the screen: zoom in, hold Before to compare, or bring it back.
struct PhotoViewer: View {
    @Environment(\.dismiss) private var dismiss
    let editor: PhotoEditor
    let item: Viewed
    @State private var image: CGImage?
    @State private var beforeImage: CGImage?
    @State private var comparing = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let shown = comparing ? (beforeImage ?? image) : image {
                ZoomablePhoto(image: shown)
            } else {
                ProgressView().tint(.white)
            }
        }
        .overlay(alignment: .top) {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel(L10n.close)
                .accessibilityIdentifier("viewer.close")
                Spacer()
                if comparing {
                    Text(L10n.before)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)
                }
                Spacer()
                // Balances the close button, so "Before" sits in the middle.
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal, 16)
        }
        .overlay(alignment: .bottom) {
            HStack {
                if item.before != nil {
                    Text(L10n.before)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .onLongPressGesture(minimumDuration: 0, maximumDistance: 60, perform: {}, onPressingChanged: { comparing = $0 })
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint(L10n.beforeHint)
                        .accessibilityIdentifier("viewer.compare")
                }
                Spacer()
                if !item.isCurrent {
                    Button(L10n.restore) {
                        editor.restore(item.state)
                        dismiss()
                    }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(editor.isWorking)
                    .accessibilityIdentifier("viewer.restore")
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .statusBarHidden()
        .task {
            image = await editor.picture(of: item.state, filling: true)
            if let before = item.before { beforeImage = await editor.picture(of: before, filling: true) }
        }
    }
}

/// The photo, fitted to the screen. Pinch to zoom, drag to move while zoomed, double-tap to fit again.
private struct ZoomablePhoto: View {
    let image: CGImage
    @State private var zoom: CGFloat = 1
    @State private var settledZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero

    var body: some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .scaledToFit()
            .scaleEffect(zoom)
            .offset(offset)
            .gesture(
                MagnifyGesture()
                    .onChanged { value in zoom = min(8, max(1, settledZoom * value.magnification)) }
                    .onEnded { _ in
                        settledZoom = zoom
                        if zoom == 1 { reset() }
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        guard zoom > 1 else { return }
                        offset = CGSize(width: settledOffset.width + value.translation.width, height: settledOffset.height + value.translation.height)
                    }
                    .onEnded { _ in settledOffset = offset }
            )
            .onTapGesture(count: 2) { withAnimation(.snappy) { reset() } }
            .accessibilityIdentifier("viewer.photo")
    }

    private func reset() {
        zoom = 1
        settledZoom = 1
        offset = .zero
        settledOffset = .zero
    }
}
