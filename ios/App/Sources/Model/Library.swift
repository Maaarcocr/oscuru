import Foundation
import ImageIO
import Observation
import OscuruCore
import OscuruEngine

/// A photo kept in the app. Its folder in the documents directory holds:
///
///     original.<ext>   a copy of the imported file, never written again; for a collage,
///                      original.collage (its `CollageManifest`) and pieces/ (the photos it is made of)
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

    /// Made of other photos (see `CollageManifest`) rather than taken or added.
    var isCollage: Bool { (originalFile as NSString).pathExtension == CollageManifest.fileExtension }

    /// When the photo was taken, from its capture details (the camera's local time); when it has
    /// none, when it was added. The library is ordered and split into days by it, as in Photos.
    @MainActor var takenAt: Date {
        guard let text = info.dateTaken else { return addedAt }
        if let known = PhotoDocument.captureTimes[text] { return known ?? addedAt }
        let parsed = PhotoDocument.captureTime.date(from: text)
        PhotoDocument.captureTimes[text] = parsed
        return parsed ?? addedAt
    }

    /// Newest first: by when taken, then by when added.
    @MainActor func isBefore(_ other: PhotoDocument) -> Bool {
        (takenAt, addedAt) > (other.takenAt, other.addedAt)
    }

    /// Capture times read so far, so sorting and drawing the grid parse each once.
    @MainActor private static var captureTimes: [String: Date?] = [:]

    /// EXIF's DateTimeOriginal, e.g. "2026:11:24 17:05:31".
    private static let captureTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()
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
        }.sorted { $0.isBefore($1) }
    }

    private func write(_ document: PhotoDocument) {
        guard let data = try? JSONEncoder().encode(document) else { return }
        try? data.write(to: folder(document.id).appending(path: "doc.json"), options: .atomic)
        if let index = photos.firstIndex(where: { $0.id == document.id }) {
            photos[index] = document
        } else {
            photos.insert(document, at: photos.firstIndex { document.isBefore($0) } ?? photos.count)
        }
    }

    /// Copies a picked file into the library and opens it once to learn what it is.
    func add(from source: URL, name: String) async throws -> PhotoDocument {
        let originalFile = "original.\(source.pathExtension.isEmpty ? "img" : source.pathExtension.lowercased())"
        return try await create(name: name) { folder in
            try FileManager.default.copyItem(at: source, to: folder.appending(path: originalFile))
            return originalFile
        }
    }

    /// A collage of developed photos (JPEGs from `AppModel.export`), arranged to start with as
    /// `CollageLayout.automatic` does.
    func addCollage(of pieces: [(file: URL, name: String)], name: String) async throws -> PhotoDocument {
        try await create(name: name) { folder in
            try FileManager.default.createDirectory(at: folder.appending(path: "pieces", directoryHint: .isDirectory), withIntermediateDirectories: true)
            var parts: [CollageManifest.Piece] = []
            for (index, piece) in pieces.enumerated() {
                let file = "pieces/\(index + 1).\(piece.file.pathExtension)"
                try FileManager.default.copyItem(at: piece.file, to: folder.appending(path: file))
                let properties = CGImageSourceCreateWithURL(piece.file as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
                let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 1
                let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 1
                parts.append(CollageManifest.Piece(file: file, name: piece.name, width: width, height: height))
            }
            let original = "original.\(CollageManifest.fileExtension)"
            try JSONEncoder().encode(CollageManifest(pieces: parts)).write(to: folder.appending(path: original), options: .atomic)
            return original
        }
    }

    /// A new photo from the same original as `document`, with these settings: a part split off it.
    func duplicate(_ document: PhotoDocument, state: EditingState, name: String) async throws -> PhotoDocument {
        let source = folder(document.id)
        let originalFile = document.originalFile
        return try await create(name: name, state: { _ in state }) { folder in
            // Copies on the phone's own disk are clones: they take no space, and originals never change.
            try FileManager.default.copyItem(at: source.appending(path: originalFile), to: folder.appending(path: originalFile))
            let pieces = source.appending(path: "pieces", directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: pieces.path) {
                try FileManager.default.copyItem(at: pieces, to: folder.appending(path: "pieces", directoryHint: .isDirectory))
            }
            return originalFile
        }
    }

    /// The one way a photo comes into the library: `fill` puts its original (and anything beside it)
    /// into a new folder and returns the original's name; the photo is opened once to learn what it
    /// is and draw its thumbnail with the settings `state` gives it (untouched, unless said otherwise).
    private func create(
        name: String, state: @escaping @Sendable (PhotoInfo) -> EditingState = { EditingState(defaults: $0.defaults) },
        fill: @escaping @Sendable (URL) throws -> String
    ) async throws -> PhotoDocument {
        let id = UUID().uuidString
        let folder = folder(id)
        let engine = engine
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let (originalFile, info, start, thumbnail) = try await Task.detached(priority: .userInitiated) {
                let originalFile = try fill(folder)
                return try engine.with(folder.appending(path: originalFile)) { session, opened in
                    var info = opened
                    info.fileName = name
                    let start = state(info)
                    let recipe = RenderRecipe(state: start, defaults: info.defaults)
                    let jpeg = try engine.jpeg(id: session, recipe: recipe, options: RenderOptions(maxEdge: PhotoRenderer.thumbnailEdge), quality: 0.8)
                    return (originalFile, info, start, jpeg)
                }
            }.value
            try thumbnail.write(to: thumbnailURL(id), options: .atomic)
            let document = PhotoDocument(id: id, name: name, addedAt: Date(), originalFile: originalFile, info: info, state: start)
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
