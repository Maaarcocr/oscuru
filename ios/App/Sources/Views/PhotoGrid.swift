import OscuruCore
import SwiftUI
import UIKit

private let gridSpace = "library.grid"
private let viewportSpace = "library.viewport"

/// The library's photos, three squares a row with hairline gaps, as in Photos. A photo opens on
/// a tap. While `selection` is set, photos are chosen instead: by tapping them, or by running a
/// finger across them.
struct PhotoGrid<Header: View>: View {
    @Environment(AppModel.self) private var model
    let photos: [PhotoDocument]
    /// Nil while photos open on a tap; otherwise the chosen ones.
    @Binding var selection: Set<String>?
    /// What scrolls above the photos.
    @ViewBuilder var header: Header

    /// A finger run across the grid, selecting (or deselecting) everything it passes.
    @State private var run: SelectionRun?
    @State private var gridWidth: CGFloat = 0
    @State private var scrollMetrics = ScrollMetrics()
    @State private var autoScroll: Task<Void, Never>?

    private struct SelectionRun {
        var start: Int
        /// Whether the run selects (it started on an unselected photo) or deselects.
        var adding: Bool
        /// The selection before the run, so moving back undoes what the run passed.
        var base: Set<String>
        /// Where the finger last was in the grid, the scroll offset then, and its height on screen.
        var finger: CGPoint
        var offsetAtFinger: CGFloat
        var screenY: CGFloat
    }

    private struct ScrollMetrics: Equatable {
        var offset: CGFloat = 0
        var insetTop: CGFloat = 0
        var insetBottom: CGFloat = 0
        var height: CGFloat = 0
    }

    private var gap: CGFloat { 2 }
    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: gap), count: 3) }
    private var chosen: Set<String> { selection ?? [] }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                header
                tiles
                    .coordinateSpace(.named(gridSpace))
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
                    .gesture(
                        SelectionPan(
                            isEnabled: selection != nil,
                            began: { start, finger, screenY in beginRun(at: start, finger: finger, screenY: screenY) },
                            moved: { finger, screenY in moveRun(to: finger, screenY: screenY, proxy: proxy) },
                            ended: endRun))
            }
            .coordinateSpace(.named(viewportSpace))
            .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                ScrollMetrics(
                    offset: geometry.contentOffset.y, insetTop: geometry.contentInsets.top, insetBottom: geometry.contentInsets.bottom,
                    height: geometry.containerSize.height)
            } action: { _, metrics in
                scrollMetrics = metrics
                // Content moving under a still finger extends the run too.
                if run != nil { extendRun() }
            }
            .onChange(of: selection == nil) { _, done in
                if done { endRun() }
            }
        }
    }

    private var tiles: some View {
        LazyVGrid(columns: columns, spacing: gap) {
            ForEach(photos) { photo in
                let thumbnail = Thumbnail(
                    url: model.library.thumbnailURL(photo.id), stamp: photo.thumbnailStamp, isRaw: photo.info.isRaw,
                    working: model.isWorking(on: photo.id), selected: selection.map { $0.contains(photo.id) })
                Group {
                    if selection != nil {
                        Button {
                            toggle(photo.id)
                        } label: {
                            thumbnail
                        }
                        .accessibilityAddTraits(chosen.contains(photo.id) ? .isSelected : [])
                    } else {
                        NavigationLink(value: photo.id) {
                            thumbnail
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("library.photo")
                .accessibilityLabel(photo.name)
            }
        }
        // New shots slide in when the camera closes.
        .animation(.snappy, value: photos.map(\.id))
    }

    // MARK: Finger runs

    /// The photo under a point of the grid. Below the last photo counts as the last photo.
    private func index(at point: CGPoint) -> Int? {
        guard gridWidth > 0, !photos.isEmpty else { return nil }
        let pitch = (gridWidth - 2 * gap) / 3 + gap
        let column = min(2, max(0, Int(point.x / pitch)))
        let row = max(0, Int((point.y / pitch).rounded(.down)))
        return min(photos.count - 1, row * 3 + column)
    }

    private func beginRun(at start: CGPoint, finger: CGPoint, screenY: CGFloat) {
        guard let index = index(at: start) else { return }
        run = SelectionRun(
            start: index, adding: !chosen.contains(photos[index].id), base: chosen, finger: finger, offsetAtFinger: scrollMetrics.offset, screenY: screenY)
        extendRun()
    }

    private func moveRun(to finger: CGPoint, screenY: CGFloat, proxy: ScrollViewProxy) {
        guard run != nil else { return }
        run?.finger = finger
        run?.offsetAtFinger = scrollMetrics.offset
        run?.screenY = screenY
        extendRun()
        if autoScroll == nil, edgeDirection() != 0 {
            autoScroll = Task { await keepScrolling(proxy) }
        }
    }

    private func endRun() {
        run = nil
        autoScroll?.cancel()
        autoScroll = nil
    }

    /// Everything from where the run started to the photo under the finger takes the start's new state.
    private func extendRun() {
        guard let run else { return }
        let finger = CGPoint(x: run.finger.x, y: run.finger.y + scrollMetrics.offset - run.offsetAtFinger)
        guard let current = index(at: finger) else { return }
        let passed = photos[min(run.start, current)...max(run.start, current)].map(\.id)
        let next = run.adding ? run.base.union(passed) : run.base.subtracting(passed)
        if next != chosen { selection = next }
    }

    /// −1 when the finger is near the top of the grid, 1 near the bottom, 0 elsewhere.
    private func edgeDirection() -> Int {
        guard let run else { return 0 }
        let zone: CGFloat = 70
        if run.screenY < scrollMetrics.insetTop + zone { return -1 }
        if run.screenY > scrollMetrics.height - scrollMetrics.insetBottom - zone { return 1 }
        return 0
    }

    /// While the finger rests near an edge, scrolls a row at a time so the run can go on.
    private func keepScrolling(_ proxy: ScrollViewProxy) async {
        defer { autoScroll = nil }
        while !Task.isCancelled, let run {
            let direction = edgeDirection()
            guard direction != 0 else { return }
            let finger = CGPoint(x: run.finger.x, y: run.finger.y + scrollMetrics.offset - run.offsetAtFinger)
            guard let current = index(at: finger) else { return }
            let target = min(photos.count - 1, max(0, current + 3 * direction))
            if target == current { return }
            withAnimation(.linear(duration: 0.2)) {
                proxy.scrollTo(photos[target].id, anchor: direction > 0 ? .bottom : .top)
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func toggle(_ id: String) {
        selection = chosen.symmetricDifference([id])
    }
}

private struct Thumbnail: View {
    let url: URL
    let stamp: Int
    let isRaw: Bool
    /// Whether the assistant is still working on it, after the photo was closed.
    let working: Bool
    /// Nil when not selecting; otherwise whether this photo is chosen.
    let selected: Bool?
    @State private var image: UIImage?

    var body: some View {
        Color(white: 0.12)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if isRaw {
                    Text(verbatim: "RAW")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .glassEffect(.regular, in: .capsule)
                        .padding(5)
                }
            }
            .overlay(alignment: .topTrailing) {
                if working {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                        .padding(5)
                        .glassEffect(.regular, in: .circle)
                        .padding(5)
                        .transition(.opacity)
                        .accessibilityLabel(L10n.working)
                }
            }
            .overlay {
                if selected == true { Color.black.opacity(0.25) }
            }
            .overlay(alignment: .bottomTrailing) {
                if selected == true {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, Color.accentColor)
                        .padding(5)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.2), value: selected)
            .animation(.easeInOut(duration: 0.3), value: working)
            .contentShape(Rectangle())
            .task(id: stamp) {
                let url = url
                image = await Task.detached { UIImage(contentsOfFile: url.path) }.value
            }
    }
}

/// A pan that starts sideways: in selection mode it runs a finger across photos to select them.
/// A pan that starts up or down is left to the scroll view, so the grid still scrolls.
private struct SelectionPan: UIGestureRecognizerRepresentable {
    var isEnabled: Bool
    /// Where the touch started and where the finger is, in the grid; the finger's height in the viewport.
    var began: (CGPoint, CGPoint, CGFloat) -> Void
    var moved: (CGPoint, CGFloat) -> Void
    var ended: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let finger = context.converter.location(in: .named(gridSpace))
        let screen = context.converter.location(in: .named(viewportSpace))
        switch recognizer.state {
        case .began:
            let moved = recognizer.translation(in: recognizer.view)
            began(CGPoint(x: finger.x - moved.x, y: finger.y - moved.y), finger, screen.y)
        case .changed:
            moved(finger, screen.y)
        default:
            ended()
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }

        /// The scroll view waits to see whether a pan is a run before it scrolls.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other.view is UIScrollView
        }
    }
}
