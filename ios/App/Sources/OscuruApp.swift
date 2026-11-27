import LockedCameraCapture
import SwiftUI

@main
struct OscuruApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var phase

    init() {
        // Composition root: the only place that decides where things are kept and who answers.
        if UITesting.isActive {
            let secrets = MemorySecrets(["openrouter-key": "sk-or-v1-test", "openrouter-user": "ui-test"])
            _model = State(initialValue: AppModel(root: UITesting.root, secrets: secrets, transport: UITesting.transport, scriptedModel: ScriptedModel()))
        } else {
            _model = State(initialValue: AppModel(root: URL.documentsDirectory.appending(path: "Oscuru", directoryHint: .isDirectory), secrets: KeychainSecrets(), transport: Network.transport))
        }
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(model)
                .preferredColorScheme(.dark)
                // The camera was asked for: by the Camera Control, the Action button or the camera control
                // (OscuruCameraIntent), or from the Lock Screen camera after Face ID.
                .onReceive(NotificationCenter.default.publisher(for: CameraLaunch.notification)) { _ in
                    if CameraLaunch.take() { model.cameraRequested = true }
                }
                .onContinueUserActivity(NSUserActivityTypeLockedCameraCapture) { _ in model.cameraRequested = true }
                // Whether the app is on screen, so that next time it knows whether it crashed (AppModel.endedOnScreen).
                .onChange(of: phase, initial: true) { _, phase in model.onScreen(phase == .active) }
                .task {
                    if CameraLaunch.take() { model.cameraRequested = true }
                    await model.account.refresh()
                    if UITesting.isActive, model.library.photos.isEmpty, let sample = UITesting.samplePhoto() {
                        _ = try? await model.library.add(from: sample, name: "Lake at dusk.jpg")
                    }
                }
        }
    }
}
