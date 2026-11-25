import AVFoundation
import AVKit
import CoreMotion
import SwiftUI

/// The camera, in the app's own terms: a viewfinder card like the photos in a thread, the lenses
/// on it, a shutter where the library's camera button was, and the last shot beside it, one tap
/// from its conversation. At the top, how it shoots: zero processing, or ProRAW with zoom between
/// the lenses (pinch, or tap a stop).
struct CameraView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var camera: Camera
    /// Opens a photo's conversation.
    let open: (String) -> Void

    @State private var focusPoint: CGPoint?
    @State private var focusStamp = 0
    @State private var dragStart: Float?
    @State private var pinchStart: Double?
    /// The zoom dial, opened from the zoom button in ProRAW; where a drag on it started; and a count
    /// that keeps it open while it is being used.
    @State private var level = Level()
    @State private var dialOpen = false
    @State private var dialStart: Double?
    @State private var dialUse = 0
    @State private var blink = false
    /// What the mode just chosen means, shown for a moment under the switch.
    @State private var modeHint: String?

    init(library: Library, simulated: Bool, open: @escaping (String) -> Void) {
        _camera = State(initialValue: Camera(library: library, simulated: simulated))
        self.open = open
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            // The viewfinder takes what it needs first; the shutter is centred in what is left.
            viewfinder
                .padding(.top, 8)
                .layoutPriority(1)
            bottomBar
                .frame(minHeight: 104, maxHeight: .infinity)
        }
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden()
        .task { await camera.start() }
        .onDisappear {
            camera.stop()
            level.stop()
        }
        .onChange(of: camera.showsGuides, initial: true) { _, shown in
            if shown { level.start() } else { level.stop() }
        }
        // A tap felt as the phone comes level.
        .sensoryFeedback(.alignment, trigger: level.angle.map(Level.isLevel) ?? false) { _, level in level }
        .onCameraCaptureEvent { event in
            // The volume buttons and Camera Control take the picture, as in the Camera app.
            if event.phase == .ended { camera.shoot() }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: camera.shots)
        .sensoryFeedback(.selection, trigger: camera.lens)
        // A tick as the zoom lands on a stop, like a dial's detent.
        .sensoryFeedback(.selection, trigger: camera.stops.first { abs($0 - camera.zoom) < 0.001 }) { _, stop in stop != nil }
        .onChange(of: camera.mode) { dialOpen = false }
        .onChange(of: camera.shots) {
            blink = true
            Task {
                try? await Task.sleep(for: .milliseconds(70))
                withAnimation(.easeOut(duration: 0.25)) { blink = false }
            }
        }
        .alert(L10n.cameraFailed, isPresented: Binding(get: { camera.problem != nil }, set: { if !$0 { camera.problem = nil } })) {
            Button(L10n.ok, role: .cancel) {}
        } message: {
            Text(camera.problem ?? "")
        }
    }

    // MARK: Top

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 30, height: 30)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel(L10n.close)
            .accessibilityIdentifier("camera.close")
            Spacer()
            modeSwitch
            Spacer()
            exposure
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .overlay(alignment: .bottom) {
            if let modeHint {
                Text(modeHint)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.horizontal, 24)
                    .offset(y: 40)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .zIndex(1)
            }
        }
        .zIndex(1)
    }

    /// How the camera shoots: zero processing or ProRAW, when this iPhone can shoot ProRAW; otherwise
    /// just RAW.
    @ViewBuilder
    private var modeSwitch: some View {
        if camera.status == .ready, camera.canShootProRAW {
            HStack(spacing: 2) {
                modeButton(.zero, title: L10n.cameraZeroProcessing, hint: L10n.cameraZeroProcessingHint, identifier: "camera.mode.zero")
                modeButton(.proRAW, title: "ProRAW", hint: L10n.cameraProRAWHint, identifier: "camera.mode.proRAW")
            }
            .padding(3)
            .glassEffect(.regular, in: .capsule)
        } else {
            Text(verbatim: "RAW")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .glassEffect(.regular, in: .capsule)
                .accessibilityHidden(true)
        }
    }

    private func modeButton(_ mode: ShootingMode, title: String, hint: String, identifier: String) -> some View {
        let selected = camera.mode == mode
        return Button {
            guard !selected else { return }
            withAnimation(.snappy) {
                camera.setMode(mode)
                modeHint = hint
            }
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                guard modeHint == hint else { return }
                withAnimation(.easeOut(duration: 0.3)) { modeHint = nil }
            }
        } label: {
            Text(verbatim: title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(selected ? Color.black : Color.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(selected ? Color.accentColor : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint(hint)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    /// The exposure compensation, when there is any: tap to go back to zero.
    @ViewBuilder
    private var exposure: some View {
        if camera.exposureBias != 0 {
            Button {
                withAnimation(.snappy) { camera.setExposureBias(0) }
            } label: {
                Text(verbatim: Self.stops(camera.exposureBias))
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .transition(.scale.combined(with: .opacity))
            .accessibilityLabel(L10n.cameraExposure)
            .accessibilityValue(Text(verbatim: Self.stops(camera.exposureBias)))
        } else {
            Color.clear.frame(width: 44, height: 44)
        }
    }

    /// "+0.7", "−1.3": stops, as a camera shows them.
    private static func stops(_ value: Float) -> String {
        let text = String(format: "%.1f", abs(value))
        return value > 0 ? "+\(text)" : "−\(text)"
    }

    // MARK: Viewfinder

    private var viewfinder: some View {
        Color(white: 0.06)
            .aspectRatio(3 / 4, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                switch camera.status {
                case .ready, .starting:
                    live
                case .denied:
                    notice(title: L10n.cameraDeniedTitle, message: L10n.cameraDeniedMessage) {
                        Button(L10n.cameraOpenSettings) {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                        .buttonStyle(.glass)
                    }
                case .unavailable:
                    notice(title: L10n.cameraUnavailableTitle, message: L10n.cameraUnavailableMessage) { EmptyView() }
                }
            }
            .overlay { Color.black.opacity(blink ? 1 : 0).allowsHitTesting(false) }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .bottom) {
                if camera.status == .ready, camera.mode == .proRAW || camera.shootingLenses.count > 1 { zoomControl }
            }
    }

    /// What the lens sees, with tap to focus and a vertical drag for exposure.
    private var live: some View {
        GeometryReader { geometry in
            ZStack {
                // Zoomed past the lens, the viewfinder shows the middle of its picture, which is what the shot is cropped to.
                Group {
                    if camera.simulated {
                        SamplePreview()
                    } else {
                        PreviewLayerView(camera: camera)
                    }
                }
                .scaleEffect(camera.magnification)
                if camera.showsGuides {
                    ThirdsGrid()
                    if let angle = level.angle, Level.isNearLevel(angle) {
                        LevelMark(angle: angle)
                    }
                }
                if let focusPoint {
                    FocusMark()
                        .position(focusPoint)
                        .id(focusStamp)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                // Where that point is in the lens's whole picture, before the viewfinder's zoom.
                let middle = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                let scale = camera.magnification
                camera.focus(at: CGPoint(x: middle.x + (location.x - middle.x) / scale, y: middle.y + (location.y - middle.y) / scale))
                show(focusAt: location)
            }
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        guard camera.mode == .proRAW else { return }
                        let start = pinchStart ?? camera.zoom
                        pinchStart = start
                        camera.setZoom(camera.snapped(start * value.magnification))
                    }
                    .onEnded { _ in pinchStart = nil }
            )
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        let start = dragStart ?? camera.exposureBias
                        dragStart = start
                        // One stop for every 120 points, brighter upwards.
                        withAnimation(.snappy) { camera.setExposureBias(start - Float(value.translation.height / 120)) }
                        if focusPoint == nil { show(focusAt: CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)) }
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .accessibilityElement()
            .accessibilityLabel(L10n.cameraViewfinder)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: camera.setExposureBias(camera.exposureBias + 1 / 3)
                case .decrement: camera.setExposureBias(camera.exposureBias - 1 / 3)
                @unknown default: break
                }
            }
            .accessibilityIdentifier("camera.viewfinder")
        }
    }

    private func show(focusAt point: CGPoint) {
        focusStamp += 1
        let stamp = focusStamp
        withAnimation(.easeOut(duration: 0.15)) { focusPoint = point }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            // Stays while the exposure is being dragged, and for a newer tap.
            guard stamp == focusStamp, dragStart == nil else { return }
            withAnimation(.easeOut(duration: 0.3)) { focusPoint = nil }
        }
    }

    private func notice<Actions: View>(title: String, message: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 10) {
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            actions().padding(.top, 6)
        }
        .padding(32)
    }

    /// The lens buttons, which in ProRAW open into the zoom dial: tap the one in use, or drag from
    /// them. Up or left zooms in, down or right zooms out; each doubling is the same distance.
    private var zoomControl: some View {
        ZStack(alignment: .bottom) {
            if dialOpen {
                ZoomDial(zoom: camera.zoom, stops: camera.stops, range: camera.zoomRange) { camera.setZoom($0) }
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottom)))
            } else {
                lensPicker
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .simultaneousGesture(
            DragGesture(minimumDistance: 6)
                .onChanged { value in
                    if !dialOpen { withAnimation(.snappy(duration: 0.2)) { dialOpen = true } }
                    dialUse += 1
                    let start = dialStart ?? camera.zoom
                    dialStart = start
                    let travel = -(value.translation.width + value.translation.height)
                    camera.setZoom(camera.snapped(start * pow(2, travel / ZoomDial.pointsPerDoubling)))
                }
                .onEnded { _ in
                    dialStart = nil
                    closeDial(after: .seconds(1.6))
                },
            including: camera.mode == .proRAW ? .all : .subviews)
    }

    /// Closes the dial when it has not been used for a while.
    private func closeDial(after delay: Duration) {
        dialUse += 1
        let use = dialUse
        Task {
            try? await Task.sleep(for: delay)
            guard use == dialUse, dialStart == nil else { return }
            withAnimation(.snappy(duration: 0.25)) { dialOpen = false }
        }
    }

    /// The lenses, or in ProRAW the zoom stops; the one in use shows the zoom now ("2.5×" between stops).
    private var lensPicker: some View {
        let stops = camera.stops
        let active = stops.last { $0 <= camera.zoom * 1.001 } ?? stops.first
        return HStack(spacing: 4) {
            ForEach(stops, id: \.self) { stop in
                let selected = stop == active
                let text = Camera.zoomText(selected ? camera.zoom : stop)
                Button {
                    if selected, camera.mode == .proRAW {
                        withAnimation(.snappy(duration: 0.2)) { dialOpen = true }
                        closeDial(after: .seconds(3))
                    } else {
                        withAnimation(.snappy) { camera.setZoom(stop) }
                    }
                } label: {
                    Text(verbatim: selected ? "\(text)×" : text)
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(selected ? Color.accentColor : Color.white)
                        .frame(width: 38, height: 38)
                        .background(Color.black.opacity(selected ? 0.35 : 0), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "\(text)×"))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .glassEffect(.regular, in: .capsule)
        .accessibilityIdentifier("camera.lenses")
    }

    // MARK: Bottom

    private var bottomBar: some View {
        HStack {
            LastShot(camera: camera, open: open)
                .frame(width: 56, height: 56)
            Spacer()
            Button {
                camera.shoot()
            } label: {
                ZStack {
                    Circle().strokeBorder(Color.white, lineWidth: 4).frame(width: 80, height: 80)
                    Circle().fill(Color.white).frame(width: 66, height: 66)
                }
            }
            .buttonStyle(ShutterStyle())
            .disabled(camera.status != .ready)
            .accessibilityLabel(L10n.cameraShutter)
            .accessibilityIdentifier("camera.shutter")
            Spacer()
            guidesButton
                .frame(width: 56, height: 56)
        }
        .padding(.horizontal, 32)
    }

    /// The thirds grid and the level, on or off.
    private var guidesButton: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { camera.setGuides(!camera.showsGuides) }
        } label: {
            Image(systemName: "grid")
                .font(.body.weight(.semibold))
                .foregroundStyle(camera.showsGuides ? Color.black : Color.white)
                .frame(width: 44, height: 44)
                .background(camera.showsGuides ? Color.accentColor : Color(white: 0.15), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.cameraGuides)
        .accessibilityAddTraits(camera.showsGuides ? .isSelected : [])
        .accessibilityIdentifier("camera.guides")
    }
}

/// Lines at the thirds of the viewfinder, for composing.
private struct ThirdsGrid: View {
    var body: some View {
        Canvas { context, size in
            var lines = Path()
            for third in [1.0 / 3, 2.0 / 3] {
                lines.move(to: CGPoint(x: size.width * third, y: 0))
                lines.addLine(to: CGPoint(x: size.width * third, y: size.height))
                lines.move(to: CGPoint(x: 0, y: size.height * third))
                lines.addLine(to: CGPoint(x: size.width, y: size.height * third))
            }
            context.stroke(lines, with: .color(.black.opacity(0.25)), lineWidth: 1.5)
            context.stroke(lines, with: .color(.white.opacity(0.55)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Which way the horizon runs across the screen, from the phone's motion sensor.
@MainActor
@Observable
final class Level {
    /// The horizon's angle on the screen, clockwise, in radians: 0 when the phone is held upright and
    /// level, about ±π/2 when it is level on its side. Nil while the phone lies flat, or has no sensor.
    private(set) var angle: Double?
    @ObservationIgnored private let motion = CMMotionManager()

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let gravity = data?.gravity else { return }
            MainActor.assumeIsolated {
                // Lying flat, there is no horizon to show.
                self?.angle = abs(gravity.z) > 0.85 ? nil : -atan2(gravity.x, -gravity.y)
            }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        angle = nil
    }

    /// How far the horizon is from the nearest level way of holding the phone (upright or on its side).
    nonisolated static func tilt(_ angle: Double) -> Double {
        angle - (angle / (.pi / 2)).rounded() * (.pi / 2)
    }

    /// Within a degree of level.
    nonisolated static func isLevel(_ angle: Double) -> Bool { abs(tilt(angle)) < .pi / 180 }

    /// Close enough to level for the mark to help; beyond that it is a different way of holding the phone.
    nonisolated static func isNearLevel(_ angle: Double) -> Bool { abs(tilt(angle)) < .pi / 9 }
}

/// The level, as in the Camera app: short marks where level is and a line that follows the horizon;
/// within a degree they meet in one yellow line.
private struct LevelMark: View {
    let angle: Double

    var body: some View {
        let level = Level.isLevel(angle)
        let square = angle - Level.tilt(angle)
        ZStack {
            HStack(spacing: 74) {
                Capsule().frame(width: 16, height: 1.5)
                Capsule().frame(width: 16, height: 1.5)
            }
            .rotationEffect(.radians(square))
            Capsule()
                .frame(width: level ? 106 : 60, height: 1.5)
                .rotationEffect(.radians(level ? square : angle))
        }
        .foregroundStyle(level ? Color.accentColor : Color.white)
        .shadow(color: .black.opacity(0.4), radius: 1)
        .animation(.snappy(duration: 0.15), value: level)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The zoom as a dial, as in the Camera app: an arc of marks that turns under the finger, with the
/// zoom now at its top and the lens stops labelled. Each doubling of the zoom is the same turn.
private struct ZoomDial: View {
    let zoom: Double
    let stops: [Double]
    let range: ClosedRange<Double>
    /// For VoiceOver, which turns it a step at a time.
    let setZoom: (Double) -> Void

    static let degreesPerDoubling = 34.0
    /// How far a finger moves for a doubling: about the same turn on the dial.
    static let pointsPerDoubling = 180.0

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let radius = width * 0.85
            let centre = CGPoint(x: width / 2, y: 46 + radius)
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.55))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
                    .frame(width: radius * 2 + 56, height: radius * 2 + 56)
                    .position(centre)
                Canvas { context, _ in
                    for mark in marks {
                        let angle = (log2(mark.zoom) - log2(zoom)) * ZoomDial.degreesPerDoubling * .pi / 180
                        guard abs(angle) < 1.1 else { continue }
                        func point(_ distance: Double) -> CGPoint {
                            CGPoint(x: centre.x + distance * sin(angle), y: centre.y - distance * cos(angle))
                        }
                        var line = Path()
                        line.move(to: point(radius))
                        line.addLine(to: point(radius - (mark.isStop ? 14 : 7)))
                        context.stroke(line, with: .color(.white.opacity(mark.isStop ? 0.95 : 0.45)), lineWidth: mark.isStop ? 2 : 1)
                        if mark.isStop {
                            let label = Text(verbatim: Camera.zoomText(mark.zoom)).font(.caption.weight(.semibold)).foregroundStyle(Color.white)
                            context.draw(context.resolve(label), at: point(radius - 30), anchor: .center)
                        }
                    }
                }
                // The zoom now, over the top of the dial.
                VStack(spacing: 3) {
                    Text(verbatim: "\(Camera.zoomText(zoom))×")
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.accentColor)
                    Capsule().fill(Color.accentColor).frame(width: 3, height: 14)
                }
                .position(x: width / 2, y: 27)
            }
        }
        .frame(height: 150)
        .clipped()
        .contentShape(Rectangle())
        .accessibilityElement()
        .accessibilityLabel(L10n.cameraZoom)
        .accessibilityValue(Text(verbatim: "\(Camera.zoomText(zoom))×"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: setZoom(zoom * pow(2, 1.0 / 8))
            case .decrement: setZoom(zoom / pow(2, 1.0 / 8))
            @unknown default: break
            }
        }
        .accessibilityIdentifier("camera.dial")
    }

    /// The stops (and the far end) labelled; small marks every eighth of a doubling between.
    private var marks: [(zoom: Double, isStop: Bool)] {
        var marks = stops.map { (zoom: $0, isStop: true) }
        if !stops.contains(where: { abs($0 / range.upperBound - 1) < 0.1 }) { marks.append((range.upperBound, true)) }
        var value = range.lowerBound
        while value <= range.upperBound * 1.0001 {
            if !marks.contains(where: { $0.isStop && abs($0.zoom / value - 1) < 0.04 }) { marks.append((value, false)) }
            value *= pow(2, 1.0 / 8)
        }
        return marks
    }
}

/// The latest photo from this camera: tap it to talk about it.
private struct LastShot: View {
    @Environment(AppModel.self) private var model
    let camera: Camera
    let open: (String) -> Void
    @State private var image: UIImage?

    var body: some View {
        Button {
            if let id = camera.lastPhotoID { open(id) }
        } label: {
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 56)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                if camera.saving > 0 {
                    Color.black.opacity(image == nil ? 0 : 0.35)
                    ProgressView().tint(.white)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                if image != nil {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(camera.lastPhotoID == nil)
        .opacity(camera.lastPhotoID == nil && camera.saving == 0 ? 0 : 1)
        .accessibilityLabel(L10n.cameraLastShot)
        .accessibilityIdentifier("camera.lastShot")
        .task(id: camera.lastPhotoID) {
            guard let id = camera.lastPhotoID else { return }
            let url = model.library.thumbnailURL(id)
            let loaded = await Task.detached { UIImage(contentsOfFile: url.path) }.value
            withAnimation(.spring(duration: 0.35)) { image = loaded }
        }
    }
}

private struct ShutterStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// Where the camera is focusing, with the sun that says a vertical drag sets the exposure.
private struct FocusMark: View {
    @State private var settled = false

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.accentColor, lineWidth: 1.5)
                .frame(width: 76, height: 76)
            Image(systemName: "sun.max.fill")
                .font(.system(size: 15))
                .foregroundStyle(Color.accentColor)
        }
        // Centred on the square, not on the square and the sun together.
        .offset(x: 13)
        .scaleEffect(settled ? 1 : 1.25)
        .onAppear { withAnimation(.snappy(duration: 0.25)) { settled = true } }
        .allowsHitTesting(false)
    }
}

/// The live picture from the lens.
private struct PreviewLayerView: UIViewRepresentable {
    let camera: Camera

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = camera.service.session
        view.previewLayer.videoGravity = .resizeAspectFill
        camera.previewLayer = view.previewLayer
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

/// UI tests have no camera: the sample photo stands in for the lens.
private struct SamplePreview: View {
    @State private var image: UIImage?

    var body: some View {
        Color(white: 0.06)
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
            .clipped()
            .task {
                image = await Task.detached { UITesting.samplePhoto().flatMap { UIImage(contentsOfFile: $0.path) } }.value
            }
    }
}
