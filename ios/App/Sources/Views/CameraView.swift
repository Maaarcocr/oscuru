import AVFoundation
import AVKit
import OscuruCore
import SwiftUI

/// The camera, in the app's own terms: a viewfinder card like the photos in a thread, the lenses
/// on it, a shutter where the library's camera button was, and the last shot beside it, one tap
/// from its conversation. At the top, how it shoots: zero processing, or ProRAW with zoom between
/// the lenses (pinch, or tap a stop), and a histogram of the live picture. Under the viewfinder,
/// the exposure as a line of values: each is the camera's until it is tapped and set on its dial.
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
    /// The value whose dial is open; where a drag on that dial started, and where it has turned to
    /// (the dial follows the finger smoothly while the value goes from stop to stop).
    @State private var openValue: CameraValue?
    @State private var turnStart: Double?
    @State private var turned: Double?
    /// While the focus is turned by hand, the viewfinder shows its middle larger.
    @State private var loupe = false
    @State private var blink = false
    /// What a choice just made means, shown for a moment under the top bar.
    @State private var hint: String?

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
            valuesLine
                .padding(.top, 6)
            bottomBar
                .frame(minHeight: 96, maxHeight: .infinity)
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
        // And as an exposure dial goes from one stop to the next.
        .sensoryFeedback(.selection, trigger: camera.exposure)
        .sensoryFeedback(.selection, trigger: camera.frames)
        .onChange(of: camera.mode) { dialOpen = false }
        .onChange(of: camera.limits) {
            // Another lens may not have what this dial sets.
            if let openValue, !camera.canSet(openValue) { self.openValue = nil }
        }
        .onChange(of: camera.values) {
            if let openValue, !camera.values.contains(openValue) { self.openValue = nil }
        }
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
            Histogram(statistics: camera.statistics)
                .opacity(camera.status == .ready ? 1 : 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .overlay(alignment: .bottom) {
            // While the frames of a shot are being taken, what to do; otherwise what a choice just made means.
            if let hint = camera.burst != nil ? L10n.cameraHoldStill : hint {
                Text(hint)
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
            withAnimation(.snappy) { camera.setMode(mode) }
            show(hint: hint)
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

    /// Says for a moment, under the top bar, what a choice just made means.
    private func show(hint text: String) {
        withAnimation(.snappy) { hint = text }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard hint == text else { return }
            withAnimation(.easeOut(duration: 0.3)) { hint = nil }
        }
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
                if camera.status == .ready {
                    if let openValue {
                        valueDial(openValue)
                    } else if camera.mode == .proRAW || camera.shootingLenses.count > 1 {
                        zoomControl
                    }
                }
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
                .scaleEffect(camera.magnification * (loupe ? 2.5 : 1))
                // The moment one lens's picture gives way to the next is softened rather than seen.
                .blur(radius: camera.switchingLens ? 14 : 0)
                .animation(.easeInOut(duration: 0.15), value: camera.switchingLens)
                // Stripes where the picture is blown, following its zoom.
                if let statistics = camera.statistics {
                    BlownMarks(statistics: statistics, rotation: camera.frameRotation, magnification: camera.magnification * (loupe ? 2.5 : 1))
                }
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
                let scale = camera.magnification * (loupe ? 2.5 : 1)
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
                        // With nothing left to the camera there is nothing to compensate.
                        guard !camera.isManual else { return }
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
                CameraDial(position: log2(camera.zoom), marks: zoomMarks, text: "\(Camera.zoomText(camera.zoom))×", name: L10n.cameraZoom) { step in
                    camera.setZoom(camera.zoom * pow(2, Double(step) / 8))
                }
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
                    camera.setZoom(camera.snapped(start * pow(2, CameraDial.Gearing.fine.turn(value.translation))))
                }
                .onEnded { _ in
                    dialStart = nil
                    closeDial(after: .seconds(1.6))
                },
            including: camera.mode == .proRAW ? .all : .subviews)
    }

    /// The lens stops (and the far end) labelled; small marks every eighth of a doubling between.
    private var zoomMarks: [DialMark] {
        let range = camera.zoomRange
        var marks = camera.stops.map { DialMark(position: log2($0), label: Camera.zoomText($0)) }
        if !camera.stops.contains(where: { abs($0 / range.upperBound - 1) < 0.1 }) {
            marks.append(DialMark(position: log2(range.upperBound), label: Camera.zoomText(range.upperBound)))
        }
        let labelled = marks
        var value = range.lowerBound
        while value <= range.upperBound * 1.0001 {
            if !labelled.contains(where: { abs($0.position - log2(value)) < 0.057 }) { marks.append(DialMark(position: log2(value))) }
            value *= pow(2, 1.0 / 8)
        }
        return marks
    }

    /// Closes the dial that is open when it has not been used for a while.
    private func closeDial(after delay: Duration) {
        dialUse += 1
        let use = dialUse
        Task {
            // A simulator in a test run can take longer than that between two steps.
            try? await Task.sleep(for: UITesting.isActive ? .seconds(60) : delay)
            guard use == dialUse, dialStart == nil, turnStart == nil else { return }
            withAnimation(.snappy(duration: 0.25)) {
                dialOpen = false
                openValue = nil
            }
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

    // MARK: Exposure

    /// The exposure as a camera shows it: aperture, time, ISO and focus, then the compensation.
    /// White is the camera's choice, changing as the light does; the accent colour is set by hand
    /// and stays. Tap one for its dial.
    private var valuesLine: some View {
        HStack(spacing: 0) {
            ForEach(camera.values) { valueButton($0) }
            compensation
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .opacity(camera.status == .ready ? 1 : 0)
    }

    private func valueButton(_ value: CameraValue) -> some View {
        let isSet = camera.isSet(value)
        let can = camera.canSet(value)
        return Button {
            withAnimation(.snappy(duration: 0.2)) {
                dialOpen = false
                turned = nil
                openValue = openValue == value ? nil : value
            }
            closeDial(after: .seconds(5))
        } label: {
            Text(verbatim: dialText(value))
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(isSet ? Color.accentColor : Color.white.opacity(can ? 1 : 0.45))
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(Color.white.opacity(openValue == value ? 0.16 : 0), in: Capsule())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!can)
        .accessibilityLabel(name(value))
        .accessibilityValue(Text(verbatim: value == .frames ? dialText(value) : "\(dialText(value)), \(isSet ? L10n.cameraSetByHand : L10n.cameraAutomatic)"))
        .accessibilityAddTraits(openValue == value ? .isSelected : [])
        .accessibilityIdentifier("camera.value.\(value.rawValue)")
    }

    /// The compensation for whatever is left to the camera: tap to go back to zero. With nothing
    /// left to it, the meter instead: how far the picture is from what the camera would choose.
    @ViewBuilder
    private var compensation: some View {
        if camera.isManual {
            HStack(spacing: 3) {
                Image(systemName: "camera.metering.center.weighted").font(.system(size: 11, weight: .semibold))
                Text(verbatim: ExposureScale.stopsText(camera.reading.offset))
            }
            .font(.footnote.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(Color.white.opacity(0.75))
            .frame(maxWidth: .infinity, minHeight: 30)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.cameraMeter)
            .accessibilityValue(Text(verbatim: ExposureScale.stopsText(camera.reading.offset)))
            .accessibilityIdentifier("camera.meter")
        } else {
            Button {
                withAnimation(.snappy) { camera.setExposureBias(0) }
            } label: {
                Text(verbatim: ExposureScale.stopsText(Double(camera.exposureBias)))
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(camera.exposureBias != 0 ? Color.accentColor : Color.white)
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.cameraExposure)
            .accessibilityValue(Text(verbatim: ExposureScale.stopsText(Double(camera.exposureBias))))
            .accessibilityIdentifier("camera.compensation")
        }
    }

    private func name(_ value: CameraValue) -> String {
        switch value {
        case .aperture: return L10n.cameraAperture
        case .time: return L10n.cameraTime
        case .iso: return "ISO"
        case .focus: return L10n.cameraFocus
        case .frames: return L10n.cameraFrames
        }
    }

    /// A value as the line and its dial write it: "ƒ1.8", "1/60", "ISO 400", "MF", "×8".
    private func dialText(_ value: CameraValue) -> String {
        switch value {
        case .aperture: return "ƒ" + ExposureScale.apertureText(camera.shown(.aperture))
        case .time: return ExposureScale.timeText(camera.shown(.time))
        case .iso: return "ISO " + ExposureScale.isoText(camera.shown(.iso))
        case .focus: return camera.isSet(.focus) ? "MF" : "AF"
        case .frames:
            let count = "×\(Int(camera.shown(.frames)))"
            guard camera.frames > 1 else { return count }
            if camera.focusBracket { return count + " " + L10n.cameraBracketFocus }
            if camera.bracket > 0 { return count + "±\(Int(camera.bracket))" }
            return count
        }
    }

    /// One of the two choices that go with frames, beside their dial: a name over its value. A tap
    /// goes to the next value, round and round.
    private func framesChoice(_ name: String, _ value: String, identifier: String, next: @escaping () -> Void) -> some View {
        Button {
            dialUse += 1
            next()
            closeDial(after: .seconds(5))
        } label: {
            VStack(spacing: 0) {
                Text(name).font(.system(size: 9, weight: .semibold)).opacity(0.75)
                Text(verbatim: value).font(.caption.weight(.bold)).monospacedDigit()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .transition(.scale.combined(with: .opacity))
        .accessibilityLabel(name)
        .accessibilityValue(Text(verbatim: value))
        .accessibilityIdentifier(identifier)
    }

    /// The seconds between frames as written: "0″", "½″", "2″".
    private static func intervalText(_ seconds: Double) -> String {
        seconds == 0.5 ? "½″" : "\(Int(seconds))″"
    }

    /// Where a value sits on its dial. A unit is a stop of light, or a third of the lens's focus travel.
    private static func position(_ value: CameraValue, _ amount: Double) -> Double {
        switch value {
        case .aperture: return 2 * log2(max(amount, 0.1))
        case .time, .iso, .frames: return log2(max(amount, 1e-9))
        case .focus: return amount * 3
        }
    }

    private static func amount(_ value: CameraValue, at position: Double) -> Double {
        switch value {
        case .aperture: return pow(2, position / 2)
        case .time, .iso, .frames: return pow(2, position)
        case .focus: return position / 3
        }
    }

    /// The stops of a value's dial: whole stops named, the thirds between as small marks. Focus has
    /// no stops, only its nearest and its farthest.
    private func marks(_ value: CameraValue) -> [DialMark] {
        if value == .focus {
            return (0...20).map { step in
                DialMark(position: Double(step) * 3 / 20, symbol: step == 0 ? "camera.macro" : step == 20 ? "mountain.2.fill" : nil)
            }
        }
        let stops = camera.stops(value)
        return stops.enumerated().map { index, stop in
            let named: Bool
            switch value {
            case .time: named = index == 0 || index == stops.count - 1 || ExposureScale.isWholeTime(stop)
            case .iso: named = index == 0 || index == stops.count - 1 || ExposureScale.isWholeISO(stop)
            case .aperture: named = index == 0 || index == stops.count - 1 || camera.limits.apertureStops.contains { abs($0 / stop - 1) < 0.03 }
            default: named = true
            }
            let text: String
            switch value {
            case .time: text = ExposureScale.timeText(stop)
            case .iso: text = ExposureScale.isoText(stop)
            case .frames: text = "×\(Int(stop))"
            default: text = ExposureScale.apertureText(stop)
            }
            return DialMark(position: Self.position(value, stop), label: named ? text : nil)
        }
    }

    /// Sets a value by hand, saying once what that means in ProRAW.
    private func set(_ value: CameraValue, to amount: Double?) {
        let wasSet = camera.isSet(value)
        camera.set(value, to: amount)
        if amount != nil, !wasSet, camera.isSet(value), camera.mode == .proRAW, value == .time || value == .iso {
            show(hint: L10n.cameraProRAWSetHint)
        }
    }

    /// The dial of the value tapped in the line. Turning it sets the value by hand; Auto hands it
    /// back to the camera.
    private func valueDial(_ value: CameraValue) -> some View {
        let dialMarks = marks(value)
        let low = dialMarks.map(\.position).min() ?? 0
        let high = dialMarks.map(\.position).max() ?? 0
        // Focus is turned finely; the rest go through stops.
        let gearing = value == .focus ? CameraDial.Gearing.fine : CameraDial.Gearing.stops
        return CameraDial(
            position: turned ?? Self.position(value, camera.shown(value)), marks: dialMarks, text: dialText(value), name: name(value), gearing: gearing
        ) { step in
            dialUse += 1
            camera.step(value, by: step)
        }
        .overlay(alignment: .topLeading) {
            // Frames are never the camera's to choose: its dial turns back to one.
            if camera.isSet(value), value != .frames {
                Button {
                    withAnimation(.snappy) { set(value, to: nil) }
                    closeDial(after: .seconds(2))
                } label: {
                    Text(L10n.cameraAuto)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .padding(.leading, 12)
                .padding(.top, 6)
                .transition(.scale.combined(with: .opacity))
                .accessibilityHint(L10n.cameraAutoHint)
                .accessibilityIdentifier("camera.auto")
            }
            // With more than one frame: how far apart their exposures are, or that their focus is.
            if value == .frames, camera.frames > 1 {
                let bracket = camera.focusBracket ? L10n.cameraBracketFocus : "±\(Int(camera.bracket))"
                framesChoice(L10n.cameraBracket, bracket, identifier: "camera.bracket") { camera.nextBracket() }
            }
        }
        .overlay(alignment: .topTrailing) {
            // And how long passes between one and the next.
            if value == .frames, camera.frames > 1 {
                framesChoice(L10n.cameraInterval, Self.intervalText(camera.interval), identifier: "camera.interval") { camera.nextInterval() }
            }
        }
        .animation(.snappy(duration: 0.2), value: camera.frames > 1)
        .simultaneousGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { drag in
                    dialUse += 1
                    let start = turnStart ?? Self.position(value, camera.shown(value))
                    turnStart = start
                    let position = min(max(start + gearing.turn(drag.translation), low), high)
                    turned = position
                    if value == .focus, !loupe { withAnimation(.snappy(duration: 0.2)) { loupe = true } }
                    set(value, to: Self.amount(value, at: position))
                }
                .onEnded { _ in
                    turnStart = nil
                    withAnimation(.snappy(duration: 0.2)) {
                        turned = nil
                        loupe = false
                    }
                    closeDial(after: .seconds(4))
                }
        )
        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottom)))
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
                    if let burst = camera.burst {
                        // The frames of this shot, filling the ring as they are taken.
                        Circle()
                            .trim(from: 0, to: Double(burst.taken) / Double(max(1, burst.of)))
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 76, height: 76)
                            .animation(.easeOut(duration: 0.15), value: burst.taken)
                    }
                }
            }
            .buttonStyle(ShutterStyle())
            .disabled(camera.status != .ready || camera.burst != nil)
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
