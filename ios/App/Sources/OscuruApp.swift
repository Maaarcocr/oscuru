import SwiftUI

@main
struct OscuruApp: App {
    @State private var model: AppModel

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
                .task {
                    await model.account.refresh()
                    if UITesting.isActive, model.library.photos.isEmpty, let sample = UITesting.samplePhoto() {
                        _ = try? await model.library.add(from: sample, name: "Lake at dusk.jpg")
                    }
                }
        }
    }
}
