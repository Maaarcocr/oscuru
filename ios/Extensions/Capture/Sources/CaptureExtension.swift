import AVFoundation
import AVKit
import ExtensionKit
import LockedCameraCapture
import SwiftUI

/// Oscuru's camera on a locked iPhone. The system keeps a capture extension running only while it
/// shows a live camera that answers the camera buttons, so this one does, and at once asks to open
/// Oscuru itself: after Face ID the app opens on its own camera, where the shooting happens.
@main
struct OscuruCapture: LockedCameraCaptureExtension {
    var body: some LockedCameraCaptureExtensionScene {
        LockedCameraCaptureUIScene { session in
            HandOver(session: session)
        }
    }
}

/// The live picture, and the way into the app: asked for at once, again on a press of a camera
/// button, and by hand when the first try was turned down.
private struct HandOver: View {
    let session: LockedCameraCaptureSession
    @State private var preview = LivePreview()
    @State private var refused = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            PreviewView(session: preview.session).ignoresSafeArea()
            VStack(spacing: 12) {
                if refused {
                    Text(String(localized: "capture.failed"))
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                }
                Button {
                    open()
                } label: {
                    Label(String(localized: "capture.open"), systemImage: "arrow.up.forward.app")
                        .font(.headline)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 48)
        }
        .onCameraCaptureEvent { event in
            if event.phase == .ended { open() }
        }
        .task {
            await preview.start()
            open()
        }
    }

    private func open() {
        Task {
            do {
                try await session.openApplication(for: NSUserActivity(activityType: NSUserActivityTypeLockedCameraCapture))
            } catch {
                refused = true
            }
        }
    }
}

/// The main lens's live picture. Nothing is captured here.
private final class LivePreview: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "oscuru.capture.preview")

    func start() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                if self.session.inputs.isEmpty, let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                    let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input)
                {
                    self.session.beginConfiguration()
                    self.session.sessionPreset = .photo
                    self.session.addInput(input)
                    self.session.commitConfiguration()
                }
                if !self.session.isRunning { self.session.startRunning() }
                continuation.resume()
            }
        }
    }
}

private struct PreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {}

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
