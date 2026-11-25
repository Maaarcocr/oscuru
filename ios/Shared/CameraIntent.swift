import AppIntents
import Foundation

/// Opens Oscuru's camera: from the Camera Control, the Action button, or the control in Control
/// Center and on the Lock Screen. Built into the app and both of its extensions, as the system
/// requires; on a locked iPhone the system opens the Lock Screen camera extension instead, which
/// hands over to the app.
struct OscuruCameraIntent: CameraCaptureIntent {
    static let title: LocalizedStringResource = "control.camera"
    static let description = IntentDescription("control.camera.description")

    @MainActor
    func perform() async throws -> some IntentResult {
        CameraLaunch.request()
        return .result()
    }
}

/// How the app hears that its camera should open: a flag for a cold launch, and a notification for
/// an app that is already running. Harmless in the extensions, where nothing listens.
@MainActor
enum CameraLaunch {
    static let notification = Notification.Name("oscuru.openCamera")
    private(set) static var pending = false

    static func request() {
        pending = true
        NotificationCenter.default.post(name: notification, object: nil)
    }

    /// True once after a request, then false until the next.
    static func take() -> Bool {
        defer { pending = false }
        return pending
    }
}
