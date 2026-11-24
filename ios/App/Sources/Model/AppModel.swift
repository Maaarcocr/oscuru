import CoreGraphics
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

    /// Files for the share sheet, one per photo: developed at full resolution in `format`, or the
    /// original files untouched when `format` is nil (a RAW stays RAW). Photos are opened one at a time.
    func exportFiles(_ documents: [PhotoDocument], format: ExportFormat?) async throws -> [URL] {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Export \(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var used: Set<String> = []
        var urls: [URL] = []
        for document in documents {
            let source = library.originalURL(document)
            let fileExtension = format.map { $0 == .heic ? "heic" : "jpg" } ?? source.pathExtension
            // Two photos with the same name get " 2", " 3", … rather than replacing each other.
            var name = document.fileName
            var number = 2
            while used.contains("\(name).\(fileExtension)".lowercased()) {
                name = "\(document.fileName) \(number)"
                number += 1
            }
            used.insert("\(name).\(fileExtension)".lowercased())
            let url = folder.appending(path: "\(name).\(fileExtension)")
            let engine = engine
            let state = document.state
            try await Task.detached(priority: .userInitiated) {
                guard let format else {
                    try FileManager.default.copyItem(at: source, to: url)
                    return
                }
                let id = "export-\(UUID().uuidString)"
                let info = try engine.open(id: id, url: source)
                defer { engine.close(id: id) }
                _ = try engine.export(id: id, recipe: RenderRecipe(state: state, defaults: info.defaults), format: format, to: url)
            }.value
            urls.append(url)
        }
        return urls
    }

    // MARK: Styles

    struct StyleResult {
        let style: SavedFilter
        /// The original with the new style, or one of the person's photos for a style from one picture.
        let styled: CGImage?
        /// The picture the style was learned from.
        let reference: CGImage?
        /// For a pair: how far the original with the style is from the edit, in 8-bit levels.
        let error: Double?
    }

    enum StyleError: Error {
        case unnamed
    }

    /// Learns a style: exactly from an original and its edit, or as a fingerprint of one picture
    /// that is matched on each photo it goes on. Saves it and returns a preview to show it worked.
    func createStyle(name: String, edited: URL, original: URL?) async throws -> StyleResult {
        let engine = engine
        let latest = library.photos.first.map { (url: library.originalURL($0), state: $0.state) }
        let made = try await Task.detached(priority: .userInitiated) { () throws -> (LookFit?, StyleFingerprint?, CGImage?, CGImage?, Data?) in
            let editedID = "style-\(UUID().uuidString)"
            _ = try engine.open(id: editedID, url: edited)
            defer { engine.close(id: editedID) }
            let editedPixels = try engine.displayPixels(id: editedID, recipe: RenderRecipe())
            let reference = try? engine.image(id: editedID, recipe: RenderRecipe(), options: RenderOptions(maxEdge: 900))
            let picture = try? engine.jpeg(id: editedID, recipe: RenderRecipe(), options: RenderOptions(maxEdge: 360), quality: 0.85)
            if let original {
                let originalID = "style-\(UUID().uuidString)"
                let info = try engine.open(id: originalID, url: original)
                defer { engine.close(id: originalID) }
                // A RAW original is developed Oscuru's neutral way, so the style is learned in Oscuru's terms.
                let base = try engine.displayPixels(id: originalID, recipe: RenderRecipe())
                let fit = try LookFitting.fit(original: base, edited: editedPixels)
                let state = try fit.applied(to: EditingState(defaults: info.defaults))
                let styled = try? engine.image(id: originalID, recipe: RenderRecipe(state: state, defaults: info.defaults), options: RenderOptions(maxEdge: 900))
                return (fit, nil, styled, reference, picture)
            }
            let fingerprint = LookFitting.fingerprint(of: editedPixels)
            var styled: CGImage?
            if let latest {
                let photoID = "style-\(UUID().uuidString)"
                if let info = try? engine.open(id: photoID, url: latest.url) {
                    defer { engine.close(id: photoID) }
                    let base = RenderRecipe(state: LookFit.base(latest.state, wholeFrame: false), defaults: info.defaults)
                    if let source = try? engine.displayPixels(id: photoID, recipe: base),
                        let state = try? LookFitting.match(source: source, fingerprint: fingerprint).applied(to: latest.state)
                    {
                        styled = try? engine.image(id: photoID, recipe: RenderRecipe(state: state, defaults: info.defaults), options: RenderOptions(maxEdge: 900))
                    }
                }
            }
            return (nil, fingerprint, styled, reference, picture)
        }.value
        let (fit, fingerprint, styled, reference, picture) = made
        let look = Look(state: try fit?.applied(to: EditingState()) ?? EditingState(), defaults: PhotoDefaults())
        guard let style = filterStore.saveStyle(name: name, look: look, fit: fit, match: fingerprint, picture: picture) else { throw StyleError.unnamed }
        return StyleResult(style: style, styled: styled, reference: reference, error: fit?.error)
    }

    /// Puts a style on photos in the library, one at a time, as a step in each one's conversation.
    func applyStyle(_ style: SavedFilter, to documents: [PhotoDocument]) async {
        for document in documents {
            let engine = engine
            let url = library.originalURL(document)
            let current = document.state
            let outcome = await Task.detached(priority: .userInitiated) { () -> (state: EditingState, original: EditingState, thumbnail: Data?)? in
                let id = "style-\(UUID().uuidString)"
                guard let info = try? engine.open(id: id, url: url) else { return nil }
                defer { engine.close(id: id) }
                let measured = RenderRecipe(state: LookFit.base(current, wholeFrame: false), defaults: info.defaults)
                guard let state = try? style.applied(to: current, defaults: info.defaults, source: { try? engine.displayPixels(id: id, recipe: measured) }) else {
                    return nil
                }
                let thumbnail = try? engine.jpeg(id: id, recipe: RenderRecipe(state: state, defaults: info.defaults), options: RenderOptions(maxEdge: 480), quality: 0.8)
                return (state, EditingState(defaults: info.defaults), thumbnail)
            }.value
            guard let outcome, outcome.state != current else { continue }
            library.save(id: document.id, state: outcome.state, revision: document.revision + 1)
            if let thumbnail = outcome.thumbnail { library.saveThumbnail(id: document.id, jpeg: thumbnail) }
            var thread = library.loadThread(document.id)
                ?? SavedThread(
                    turns: [Turn(id: "original", kind: .original, result: outcome.original)]
                        + (current != outcome.original ? [Turn(id: UUID().uuidString, kind: .earlier, result: current)] : []),
                    conversation: [])
            thread.turns.append(Turn(id: UUID().uuidString, kind: .filter(style.name), result: outcome.state))
            library.saveThread(document.id, thread)
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
