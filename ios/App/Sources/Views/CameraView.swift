import AVFoundation
import AVKit
import SwiftUI

/// The camera, in the app's own terms: a viewfinder card like the photos in a thread, the lenses
/// on it, a shutter where the library's camera button was, and the last shot beside it, one tap
/// from its conversation.
struct CameraView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var camera: Camera
    /// Opens a photo's conversation.
    let open: (String) -> Void

    @State private var focusPoint: CGPoint?
    @State private var focusStamp = 0
    @State private var dragStart: Float?
    @State private var blink = false

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
        .onDisappear { camera.stop() }
        .onCameraCaptureEvent { event in
            // The volume buttons and Camera Control take the picture, as in the Camera app.
            if event.phase == .ended { camera.shoot() }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: camera.shots)
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
            Text(verbatim: "RAW")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .glassEffect(.regular, in: .capsule)
                .accessibilityHidden(true)
            Spacer()
            exposure
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
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
                if camera.status == .ready, camera.lenses.count > 1 { lensPicker.padding(.bottom, 14) }
            }
    }

    /// What the lens sees, with tap to focus and a vertical drag for exposure.
    private var live: some View {
        GeometryReader { geometry in
            ZStack {
                if camera.simulated {
                    SamplePreview()
                } else {
                    PreviewLayerView(camera: camera)
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
                camera.focus(at: location)
                show(focusAt: location)
            }
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

    private var lensPicker: some View {
        HStack(spacing: 4) {
            ForEach(camera.lenses) { lens in
                let selected = lens == camera.lens
                Button {
                    withAnimation(.snappy) { camera.select(lens) }
                } label: {
                    Text(verbatim: selected ? "\(lens.label)×" : lens.label)
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(selected ? Color.accentColor : Color.white)
                        .frame(width: 38, height: 38)
                        .background(Color.black.opacity(selected ? 0.35 : 0), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "\(lens.label)×"))
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
            Color.clear.frame(width: 56, height: 56)
        }
        .padding(.horizontal, 32)
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
