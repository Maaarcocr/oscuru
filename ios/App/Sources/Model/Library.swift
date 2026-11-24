import Foundation
import Observation
import OscuruCore
import OscuruEngine

/// A photo kept in the app. Its folder in the documents directory holds:
///
///     original.<ext>   a copy of the imported file, never written again
///     doc.json         this record: what the engine reported, and a copy of the photo's settings now
///     thumb.jpg        the library thumbnail
///     conversation/    the thread with the assistant: transcript.jsonl and the pictures it was sent
struct PhotoDocument: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var addedAt: Date
    var originalFile: String
    var info: PhotoInfo
    /// The photo's settings now: a copy of what its conversation last recorded, kept here so the
    /// library can show and export photos without opening their conversations.
    var state: EditingState
    /// Changes when the thumbnail is redrawn, so views showing it reload.
    var thumbnailStamp = 0
}

extension PhotoDocument {
    /// The photo's name, usable as a file name (without an extension).
    var fileName: String {
        let name = (name as NSString).deletingPathExtension
            .replacingOccurrences(of: ":", with: ".")
            .replacingOccurrences(of: "/", with: "-")
        return name.isEmpty ? "Oscuru" : name
    }
}

@MainActor
@Observable
final class Library {
    private(set) var photos: [PhotoDocument] = []
    private let root: URL
    private let engine: Engine

    init(root: URL, engine: Engine) {
        self.root = root
        self.engine = engine
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        load()
    }

    func folder(_ id: String) -> URL { root.appending(path: id, directoryHint: .isDirectory) }
    func originalURL(_ document: PhotoDocument) -> URL { folder(document.id).appending(path: document.originalFile) }
    func thumbnailURL(_ id: String) -> URL { folder(id).appending(path: "thumb.jpg") }
    func document(_ id: String) -> PhotoDocument? { photos.first { $0.id == id } }

    private func load() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        photos = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appending(path: "doc.json")) else { return nil }
            return try? decoder.decode(PhotoDocument.self, from: data)
        }.sorted { $0.addedAt > $1.addedAt }
    }

    private func write(_ document: PhotoDocument) {
        guard let data = try? JSONEncoder().encode(document) else { return }
        try? data.write(to: folder(document.id).appending(path: "doc.json"), options: .atomic)
        if let index = photos.firstIndex(where: { $0.id == document.id }) {
            photos[index] = document
        } else {
            photos.insert(document, at: 0)
        }
    }

    /// Copies a picked file into the library and opens it once to learn what it is.
    func add(from source: URL, name: String) async throws -> PhotoDocument {
        let id = UUID().uuidString
        let folder = folder(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileExtension = source.pathExtension.isEmpty ? "img" : source.pathExtension.lowercased()
        let originalFile = "original.\(fileExtension)"
        let original = folder.appending(path: originalFile)
        let engine = engine
        do {
            try FileManager.default.copyItem(at: source, to: original)
            let (info, thumbnail) = try await Task.detached(priority: .userInitiated) {
                try engine.with(original) { session, opened in
                    var info = opened
                    info.fileName = name
                    let recipe = RenderRecipe(state: EditingState(defaults: info.defaults), defaults: info.defaults)
                    return (info, try engine.jpeg(id: session, recipe: recipe, options: RenderOptions(maxEdge: PhotoRenderer.thumbnailEdge), quality: 0.8))
                }
            }.value
            try thumbnail.write(to: thumbnailURL(id), options: .atomic)
            let document = PhotoDocument(id: id, name: name, addedAt: Date(), originalFile: originalFile, info: info, state: EditingState(defaults: info.defaults))
            write(document)
            return document
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// Keeps the photo's settings after a change.
    func save(id: String, state: EditingState) {
        guard var document = document(id), document.state != state else { return }
        document.state = state
        write(document)
    }

    func saveThumbnail(id: String, jpeg: Data) {
        guard var document = document(id) else { return }
        try? jpeg.write(to: thumbnailURL(id), options: .atomic)
        document.thumbnailStamp += 1
        write(document)
    }

    /// The thread saved by versions before the transcript, if there is one: what the person saw
    /// and what the model had been told.
    func loadThread(_ id: String) -> TranscriptEntry.Imported? {
        guard let data = try? Data(contentsOf: folder(id).appending(path: "thread.json")) else { return nil }
        return try? JSONDecoder().decode(TranscriptEntry.Imported.self, from: data)
    }

    /// Where the photo's conversation with the assistant is kept (see `Transcript`).
    func conversationFolder(_ id: String) -> URL { folder(id).appending(path: "conversation", directoryHint: .isDirectory) }

    func delete(id: String) {
        try? FileManager.default.removeItem(at: folder(id))
        photos.removeAll { $0.id == id }
    }
}
