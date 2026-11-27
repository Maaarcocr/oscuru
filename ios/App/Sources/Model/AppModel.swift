import CoreGraphics
import Foundation
import Observation
import OscuruCore
import OscuruEngine
import Photos
import UIKit

/// The app's composition root: the library, the account, the styles and the engine, and the one
/// place photos are opened, exported and deleted.
@MainActor
@Observable
final class AppModel {
    let engine: Engine
    let library: Library
    let account: Account
    let styleStore: StyleStore
    /// The prompts the person keeps to send with a tap.
    let prompts: PromptStore
    /// The styles, mirrored here so views update when a script saves or deletes one.
    private(set) var styles: [Style]
    /// Set in UI tests to play back a prepared conversation instead of calling OpenRouter.
    private let scriptedModel: ModelClient?

    /// Photos open in an editor: on screen, or closed while the assistant still works on them.
    private var editors: [String: PhotoEditor] = [:]
    /// How many screens show each photo.
    private var viewers: [String: Int] = [:]
    /// Each photo's conversation, opened once: a transcript has one writer.
    private var transcripts: [String: Task<Transcript, Error>] = [:]

    /// Whether the app ended last time while on screen: it crashed (or iOS stopped it for memory)
    /// rather than being left. Work it was doing then is not taken up again by itself, since it
    /// may be what made it crash; Continue takes it up.
    let endedOnScreen = UserDefaults.standard.bool(forKey: AppModel.onScreenKey)
    private static let onScreenKey = "app.onScreen"

    /// The app is on screen, or has left it (backgrounded, or about to be closed from the switcher).
    func onScreen(_ shown: Bool) {
        UserDefaults.standard.set(shown, forKey: AppModel.onScreenKey)
    }

    init(root: URL, secrets: SecretStore, transport: @escaping HTTPTransport, scriptedModel: ModelClient? = nil) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        engine = Engine(models: Bundle.main.url(forResource: "Models", withExtension: nil))
        library = Library(root: root.appending(path: "photos", directoryHint: .isDirectory), engine: engine)
        account = Account(secrets: secrets, folder: root, transport: transport)
        styleStore = StyleStore(file: root.appending(path: "filters.json"))
        prompts = PromptStore(defaults: UITesting.isActive ? nil : .standard)
        styles = styleStore.styles
        self.scriptedModel = scriptedModel
        styleStore.onChange = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.styles = self.styleStore.styles
            }
        }
        // iOS does not let an app in the background use the graphics processor: the assistant's
        // renders there are drawn on the processor instead.
        let engine = engine
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in engine.isInBackground = true }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { _ in engine.isInBackground = false }
    }

    /// Set when something outside the app asks for its camera (see `CameraLaunch`); the library opens
    /// it and sets this back.
    var cameraRequested = false

    // MARK: Photos

    /// Opens a photo for editing, or the editor it already has (the assistant may still be at
    /// work on it). Work the app was closed during carries on, when `resuming`: when the person
    /// opens the photo, not when something is done to it from the library. The engine keeps the
    /// photo open until it is closed and the assistant is done.
    func open(_ document: PhotoDocument, resuming: Bool = true) async throws -> PhotoEditor {
        viewers[document.id, default: 0] += 1
        if let editor = editors[document.id] { return editor }
        do {
            // A fresh name per opening, so closing an earlier opening of the same photo cannot close this one.
            let id = "\(document.id)-\(UUID().uuidString.prefix(8))"
            let url = library.originalURL(document)
            let engine = engine
            var info = try await Rendering.run(for: id) { try engine.open(id: id, url: url) }
            info.fileName = document.name
            // How the camera framed it lives in the photo's record, not in the file.
            info.defaults.framing = document.info.defaults.framing
            info.frames = document.info.frames
            let transcript = try await openTranscript(for: document, original: EditingState(defaults: info.defaults))
            if let editor = editors[document.id] {
                // Opened twice at once: the first one won.
                Rendering.later(for: id) { engine.close(id: id) }
                return editor
            }
            let renderer = PhotoRenderer(engine: engine, id: id, info: info, styles: styleStore)
            let account = account
            let scripted = scriptedModel
            let (entries, updates) = await transcript.observe()
            let editor = PhotoEditor(
                document: library.document(document.id) ?? document, renderer: renderer, transcript: transcript, entries: entries, updates: updates,
                library: library, account: account
            ) {
                scripted ?? account.client()
            }
            editor.onIdle = { [weak self] in self?.releaseIfUnused(document.id) }
            editors[document.id] = editor
            if resuming, !endedOnScreen { editor.resumeIfInterrupted() }
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
            // In its turn, after any picture of it still waiting: never on the main thread, which
            // would wait for whatever the photo is rendering.
            Rendering.later(for: session) { engine.close(id: session) }
        }
    }

    /// Whether the assistant is working on this photo now.
    func isWorking(on id: String) -> Bool { editors[id]?.isWorking ?? false }

    /// The photo's conversation. A new one starts from the original photo, or from the thread an
    /// earlier version saved, and takes in any edits it has not heard of. After that the
    /// conversation is the photo's history. Opened once, however many ask at the same time.
    private func openTranscript(for document: PhotoDocument, original: EditingState) async throws -> Transcript {
        if let opening = transcripts[document.id] { return try await opening.value }
        let folder = library.conversationFolder(document.id)
        let saved = library.loadThread(document.id)
        let state = document.state
        let opening = Task { () throws -> Transcript in
            let transcript = try Transcript(folder: folder)
            guard await transcript.isEmpty else { return transcript }
            if let saved {
                try await transcript.append(.imported(saved))
            } else {
                try await transcript.append(.edit(.init(kind: .original, state: original)))
            }
            if Conversation(await transcript.entries).state != state {
                try await transcript.append(.edit(.init(kind: .earlier, state: state)))
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
                let engine = engine
                let session = editor.renderer.id
                Rendering.later(for: session) { engine.close(id: session) }
                editors[id] = nil
            }
            viewers[id] = nil
            transcripts[id] = nil
            library.delete(id: id)
        }
    }

    /// Runs `work` with a renderer for a photo: its editor's while it is open, otherwise (or for
    /// work of its `own`) one opened for the occasion.
    private func render<T: Sendable>(_ document: PhotoDocument, own: Bool = false, _ work: @escaping @Sendable (PhotoRenderer) throws -> T) async throws -> T {
        let open = own ? nil : editors[document.id]?.renderer
        let engine = engine
        let styles = styleStore
        let url = library.originalURL(document)
        // In the photo's turn, so a photo closing meanwhile closes after this is done.
        return try await Rendering.run(for: open?.id ?? (own ? "own \(document.id)" : document.id)) {
            if let open { return try work(open) }
            return try PhotoRenderer.with(url, engine: engine, styles: styles, work)
        }
    }

    /// Every photo's conversation with the assistant in one JSON file, for the share sheet: what
    /// was said and done, and how long each step took (`TranscriptExport`). Read from the
    /// transcripts as they are on disk; photos without a conversation are left out.
    func exportConversations() async throws -> URL {
        let photos = library.photos.map { (id: $0.id, name: $0.name, folder: library.conversationFolder($0.id)) }
        let bundle = Bundle.main.infoDictionary ?? [:]
        let app = "\(bundle["CFBundleShortVersionString"] as? String ?? "?") (\(bundle["CFBundleVersion"] as? String ?? "?"))"
        let system = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        var name = utsname()
        uname(&name)
        let device = withUnsafeBytes(of: &name.machine) { bytes in String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self) }
        return try await Task.detached(priority: .userInitiated) {
            let read = photos.compactMap { photo -> TranscriptExport.Photo? in
                let entries = Transcript.entries(in: photo.folder)
                return entries.isEmpty ? nil : TranscriptExport.Photo(id: photo.id, name: photo.name, entries: entries)
            }
            let folder = FileManager.default.temporaryDirectory.appending(path: "Export \(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let day = Date.now.formatted(.iso8601.year().month().day())
            let file = folder.appending(path: "Oscuru conversations \(day).json")
            try TranscriptExport.data(photos: read, app: app, device: device, system: system).write(to: file)
            return file
        }.value
    }

    /// Files for the share sheet, one per photo, in the order given: each developed at full
    /// resolution as a JPEG, or, for `original`, the file as it was taken or added (a RAW stays RAW).
    func export(_ ids: [String], original: Bool) async throws -> [URL] {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Export \(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var used: Set<String> = []
        var urls: [URL] = []
        for document in ids.compactMap({ library.document($0) }) {
            let source = library.originalURL(document)
            // A collage's original is the arrangement it was made in, developed.
            let copy = original && !document.isCollage
            let fileExtension = copy ? source.pathExtension : "jpg"
            // Two photos with the same name get " 2", " 3", … rather than replacing each other.
            var name = document.fileName
            var number = 2
            while used.contains("\(name).\(fileExtension)".lowercased()) {
                name = "\(document.fileName) \(number)"
                number += 1
            }
            used.insert("\(name).\(fileExtension)".lowercased())
            let url = folder.appending(path: "\(name).\(fileExtension)")
            if copy {
                try await Task.detached(priority: .userInitiated) { try FileManager.default.copyItem(at: source, to: url) }.value
            } else {
                let state = original ? EditingState(defaults: document.info.defaults) : document.state
                // On a copy of its own, so the photo's pictures keep coming while it is developed at full size.
                try await render(document, own: true) { try $0.export(state, to: url) }
            }
            urls.append(url)
        }
        return urls
    }

    /// A collage of photos as they are now (developed at full size, as `export` does), arranged to
    /// start with; it opens like any photo, and the assistant arranges it from there.
    func combine(_ ids: [String]) async throws -> PhotoDocument {
        let files = try await export(ids, original: false)
        defer { if let folder = files.first?.deletingLastPathComponent() { try? FileManager.default.removeItem(at: folder) } }
        let names = ids.compactMap { library.document($0)?.name }
        return try await library.addCollage(of: zip(files, names).map { (file: $0, name: $1) }, name: L10n.collageName)
    }

    /// Develops photos as `export` does and adds them to the person's photo library, asking only to
    /// add (never to read it). Each keeps its capture details, so Photos files it under when it was taken.
    func saveToPhotos(_ ids: [String]) async throws {
        let access = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard access == .authorized || access == .limited else { throw PhotosAccessDenied() }
        let urls = try await export(ids, original: false)
        defer { if let folder = urls.first?.deletingLastPathComponent() { try? FileManager.default.removeItem(at: folder) } }
        try await PHPhotoLibrary.shared().performChanges {
            for url in urls {
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = url.lastPathComponent
                PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: options)
            }
        }
    }

    // MARK: Styles

    /// Puts a style on photos, one at a time, each as a step in its own conversation: through the
    /// photo's editor, like every other change.
    func apply(_ style: Style, to ids: [String]) async {
        for document in ids.compactMap({ library.document($0) }) {
            guard let editor = try? await open(document, resuming: false) else { continue }
            await editor.apply(style)
            close(editor)
        }
    }

    struct StyleResult: Sendable {
        let style: Style
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

    /// Learns a style from pictures: exactly, from an original and its edit, or as a fingerprint
    /// of one picture that is matched on each photo it goes on. Saves it and returns pictures
    /// that show it at work.
    func createStyle(name: String, edited: URL, original: URL?) async throws -> StyleResult {
        guard !StyleCollection.cleanName(name).isEmpty else { throw StyleError.unnamed }
        let engine = engine
        let styles = styleStore
        let latest = library.photos.first.map { (url: library.originalURL($0), state: $0.state) }
        let preview = 900.0
        return try await Rendering.run(for: "new style") {
            try PhotoRenderer.with(edited, engine: engine, styles: styles) { look in
                guard let wanted = look.pixels(of: look.original) else { throw LookFitting.Failure.empty }
                var recipe = Style.Recipe.match(LookFitting.fingerprint(of: wanted))
                var styled: CGImage?
                var error: Double?
                if let original {
                    // A RAW original is developed Oscuru's neutral way, so the style is learned in Oscuru's terms.
                    try PhotoRenderer.with(original, engine: engine, styles: styles) { source in
                        guard let base = source.pixels(of: source.original) else { throw LookFitting.Failure.empty }
                        let fit = try LookFitting.fit(original: base, edited: wanted)
                        recipe = .fit(fit)
                        error = fit.error
                        styled = try? source.picture(of: fit.applied(to: source.original), edge: preview)
                    }
                }
                guard let style = styles.save(name: name, recipe: recipe, picture: look.jpeg(of: look.original, edge: PhotoRenderer.styleEdge)) else {
                    throw StyleError.unnamed
                }
                if styled == nil, let latest {
                    styled = try? PhotoRenderer.with(latest.url, engine: engine, styles: styles) { photo in
                        try photo.picture(of: photo.apply(style, to: latest.state), edge: preview)
                    }
                }
                return StyleResult(style: style, styled: styled, reference: try? look.picture(of: look.original, edge: preview), error: error)
            }
        }
    }
}

/// The person has not let Oscuru add to their photo library.
struct PhotosAccessDenied: Error {}
