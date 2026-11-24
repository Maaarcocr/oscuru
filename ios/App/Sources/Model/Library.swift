import Foundation
import Observation
import OscuruCore
import OscuruEngine

/// A photo kept in the app. Its folder in the documents directory holds:
///
///     original.<ext>   a copy of the imported file, never written again
///     doc.json         this record: what the engine reported, the editing state and its revision
///     thumb.jpg        the library thumbnail
struct PhotoDocument: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var addedAt: Date
    var originalFile: String
    var info: PhotoInfo
    var state: EditingState
    var revision: Int
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
                var info = try engine.open(id: id, url: original)
                defer { engine.close(id: id) }
                info.fileName = name
                let state = EditingState(defaults: info.defaults)
                let thumbnail = try engine.jpeg(id: id, recipe: RenderRecipe(state: state, defaults: info.defaults), options: RenderOptions(maxEdge: 480), quality: 0.8)
                return (info, thumbnail)
            }.value
            try thumbnail.write(to: thumbnailURL(id), options: .atomic)
            let document = PhotoDocument(
                id: id, name: name, addedAt: Date(), originalFile: originalFile, info: info, state: EditingState(defaults: info.defaults), revision: 1)
            write(document)
            return document
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// Saves the editing state after a change.
    func save(id: String, state: EditingState, revision: Int) {
        guard var document = document(id) else { return }
        document.state = state
        document.revision = revision
        write(document)
    }

    func saveThumbnail(id: String, jpeg: Data) {
        guard var document = document(id) else { return }
        try? jpeg.write(to: thumbnailURL(id), options: .atomic)
        document.thumbnailStamp += 1
        write(document)
    }

    /// A picture attached to an instruction, kept with the photo it was attached to.
    func referenceURL(_ id: String, _ name: String) -> URL {
        folder(id).appending(path: "references", directoryHint: .isDirectory).appending(path: name)
    }

    /// Keeps a copy of an attached picture with the photo. Returns its stored name.
    func saveReference(_ id: String, from source: URL) throws -> String {
        let directory = folder(id).appending(path: "references", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).\(source.pathExtension.isEmpty ? "img" : source.pathExtension.lowercased())"
        try FileManager.default.copyItem(at: source, to: directory.appending(path: name))
        return name
    }

    func loadThread(_ id: String) -> SavedThread? {
        guard let data = try? Data(contentsOf: folder(id).appending(path: "thread.json")) else { return nil }
        return try? JSONDecoder().decode(SavedThread.self, from: data)
    }

    func saveThread(_ id: String, _ thread: SavedThread) {
        guard let data = try? JSONEncoder().encode(thread) else { return }
        try? data.write(to: folder(id).appending(path: "thread.json"), options: .atomic)
    }

    func delete(id: String) {
        try? FileManager.default.removeItem(at: folder(id))
        photos.removeAll { $0.id == id }
    }
}
