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
        engine = Engine(models: Bundle.main.url(forResource: "Models", withExtension: nil))
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

    /// Photos open in an editor: on screen, or closed while the assistant still works on them.
    private var editors: [String: PhotoEditor] = [:]
    /// How many screens show each photo.
    private var viewers: [String: Int] = [:]
    /// Each photo's conversation, opened once: a transcript has one writer.
    private var transcripts: [String: Task<Transcript, Error>] = [:]

    /// Opens a photo for editing, or the editor it already has (the assistant may still be at
    /// work on it). Work the app was closed during carries on. The engine keeps the photo open
    /// until it is closed and the assistant is done.
    func open(_ document: PhotoDocument) async throws -> PhotoEditor {
        viewers[document.id, default: 0] += 1
        if let editor = editors[document.id] { return editor }
        do {
            // A fresh name per opening, so closing an earlier opening of the same photo cannot close this one.
            let id = "\(document.id)-\(UUID().uuidString.prefix(8))"
            let url = library.originalURL(document)
            let engine = engine
            var info = try await Task.detached(priority: .userInitiated) { try engine.open(id: id, url: url) }.value
            info.fileName = document.name
            let transcript = try await openTranscript(for: document, original: EditingState(defaults: info.defaults))
            if let editor = editors[document.id] {
                // Opened twice at once: the first one won.
                engine.close(id: id)
                return editor
            }
            let renderer = PhotoRenderer(engine: engine, id: id, info: info, filters: filterStore)
            let account = account
            let scripted = scriptedModel
            let (entries, updates) = await transcript.observe()
            let current = library.document(document.id) ?? document
            let editor = PhotoEditor(
                document: current, info: info, renderer: renderer, transcript: transcript, entries: entries, updates: updates, library: library, account: account
            ) {
                scripted ?? account.client()
            }
            editor.onIdle = { [weak self] in self?.releaseIfUnused(document.id) }
            editors[document.id] = editor
            editor.resumeIfInterrupted()
            return editor
        } catch {
            viewers[document.id, default: 1] -= 1
            throw error
        }
    }

    /// A screen stops showing the photo. The assistant keeps working if it is; the photo closes
    /// once nothing shows it and the assistant is done.
    func close(_ editor: PhotoEditor) {
        let id = editor.document.id
        viewers[id] = max(0, viewers[id, default: 1] - 1)
        releaseIfUnused(id)
    }

    private func releaseIfUnused(_ id: String) {
        guard viewers[id, default: 0] == 0, let editor = editors[id], !editor.isWorking else { return }
        editors[id] = nil
        editor.detach()
        let engine = engine
        let session = editor.renderer.id
        Task {
            await editor.saveThumbnail()
            engine.close(id: session)
        }
    }

    /// Whether the assistant is working on this photo now.
    func isWorking(on id: String) -> Bool { editors[id]?.isWorking ?? false }

    /// The photo's conversation. The first time, it starts from the thread an earlier version
    /// saved, or from the original photo (and the edits it already had). Opened once, however
    /// many ask at the same time.
    private func openTranscript(for document: PhotoDocument, original: EditingState) async throws -> Transcript {
        if let opening = transcripts[document.id] { return try await opening.value }
        let folder = library.conversationFolder(document.id)
        let saved = library.loadThread(document.id)
        let state = document.state
        let opening = Task { () throws -> Transcript in
            let transcript = try Transcript(folder: folder)
            guard await transcript.isEmpty else { return transcript }
            if let saved {
                try await transcript.append(.imported(.init(turns: saved.turns, conversation: saved.conversation)))
            } else {
                try await transcript.append(.edit(.init(kind: .original, state: original)))
                if state != original { try await transcript.append(.edit(.init(kind: .earlier, state: state))) }
            }
            return transcript
        }
        transcripts[document.id] = opening
        do {
            return try await opening.value
        } catch {
            transcripts[document.id] = nil
            throw error
        }
    }

    /// Deletes photos, stopping the assistant on them first.
    func delete(_ ids: [String]) {
        for id in ids {
            if let editor = editors[id] {
                editor.onIdle = nil
                editor.stop()
                editor.detach()
                engine.close(id: editor.renderer.id)
                editors[id] = nil
            }
            viewers[id] = nil
            transcripts[id] = nil
            library.delete(id: id)
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
            // A photo open in an editor changes there, so there is one editing path.
            if let editor = editors[document.id] {
                editor.apply(style)
                continue
            }
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
            guard let outcome, outcome.state != current, editors[document.id] == nil else { continue }
            guard let transcript = try? await openTranscript(for: document, original: outcome.original) else { continue }
            guard (try? await transcript.append(.edit(.init(kind: .filter(style.name), state: outcome.state)))) != nil else { continue }
            library.save(id: document.id, state: outcome.state, revision: document.revision + 1)
            if let thumbnail = outcome.thumbnail { library.saveThumbnail(id: document.id, jpeg: thumbnail) }
        }
    }
}
