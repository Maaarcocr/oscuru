import Foundation
import OscuruCore

/// The person's styles on disk, each with the small picture that stands for it in the app.
/// Scripts reach this from their own thread while the screen reads it from the main one, so every
/// access goes through a lock.
final class StyleStore: @unchecked Sendable {
    private let lock = NSLock()
    private var collection = StyleCollection()
    /// The list's file; it keeps the name it was first saved under.
    private let file: URL?
    /// Called (on any thread) after the styles change.
    var onChange: (@Sendable () -> Void)?

    init(file: URL?) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(StyleCollection.self, from: data) {
            collection = saved
        }
    }

    var styles: [Style] {
        lock.lock()
        defer { lock.unlock() }
        return collection.styles
    }

    func named(_ name: String) -> Style? {
        lock.lock()
        defer { lock.unlock() }
        return collection.named(name)
    }

    private func change<T>(_ work: (inout StyleCollection) -> T) -> T {
        lock.lock()
        let result = work(&collection)
        let snapshot = collection
        lock.unlock()
        if let file, let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: file, options: .atomic) }
        onChange?()
        return result
    }

    /// Saves a style under a name, replacing one of the same name, with a picture to show it by.
    /// Nil when the name is empty.
    @discardableResult
    func save(name: String, recipe: Style.Recipe, picture: Data?) -> Style? {
        let saved = change { $0.save(name: name, recipe: recipe, id: UUID().uuidString, now: Date()) }
        if let saved, let picture, let url = pictureURL(saved.id) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? picture.write(to: url, options: .atomic)
        }
        return saved
    }

    func pictureURL(_ id: String) -> URL? {
        file?.deletingLastPathComponent().appending(path: "styles", directoryHint: .isDirectory).appending(path: "\(id).jpg")
    }

    func rename(id: String, to name: String) -> Bool {
        change { $0.rename(id: id, to: name) }
    }

    func delete(id: String) {
        change { $0.delete(id: id) }
        if let url = pictureURL(id) { try? FileManager.default.removeItem(at: url) }
    }
}
