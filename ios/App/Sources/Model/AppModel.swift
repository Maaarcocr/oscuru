import Foundation
import Observation
import OscuruCore
import OscuruEngine

/// The app's composition root: the library, the account, the saved filters and the engine.
@MainActor
@Observable
final class AppModel {
    let engine: Engine
    let library: Library
    let account: Account
    let filterStore: FilterStore
    /// The saved filters, mirrored here so views update when a script saves or deletes one.
    private(set) var filters: [SavedFilter]
    /// Set in UI tests to play back a prepared conversation instead of calling OpenRouter.
    private let scriptedModel: ModelClient?

    init(root: URL, secrets: SecretStore, transport: @escaping HTTPTransport, scriptedModel: ModelClient? = nil) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        engine = Engine()
        library = Library(root: root.appending(path: "photos", directoryHint: .isDirectory), engine: engine)
        account = Account(secrets: secrets, folder: root, transport: transport)
        filterStore = FilterStore(file: root.appending(path: "filters.json"))
        filters = filterStore.filters
        self.scriptedModel = scriptedModel
        filterStore.onChange = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.filters = self.filterStore.filters
            }
        }
    }

    /// Opens a photo for editing. The engine keeps it open until `close`.
    func open(_ document: PhotoDocument) async throws -> PhotoEditor {
        // A fresh name per opening, so closing an earlier opening of the same photo cannot close this one.
        let id = "\(document.id)-\(UUID().uuidString.prefix(8))"
        let url = library.originalURL(document)
        let engine = engine
        var info = try await Task.detached(priority: .userInitiated) { try engine.open(id: id, url: url) }.value
        info.fileName = document.name
        let renderer = PhotoRenderer(engine: engine, id: id, info: info, filters: filterStore)
        let account = account
        let scripted = scriptedModel
        return PhotoEditor(document: document, info: info, renderer: renderer, library: library, account: account) {
            scripted ?? account.client()
        }
    }

    func close(_ editor: PhotoEditor) {
        editor.stop()
        let engine = engine
        let id = editor.renderer.id
        Task {
            await editor.saveThumbnail()
            engine.close(id: id)
        }
    }
}
