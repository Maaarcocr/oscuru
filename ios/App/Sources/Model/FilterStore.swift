import Foundation
import OscuruCore

/// The person's saved styles (filters), on disk, with the picture each style learned from pictures came from. Scripts reach this from their own thread while the screen
/// reads it from the main one, so every access goes through a lock.
final class FilterStore: @unchecked Sendable {
    private let lock = NSLock()
    private var collection = FilterCollection()
    private let file: URL?
    /// Called (on any thread) after the saved filters change.
    var onChange: (@Sendable () -> Void)?

    init(file: URL?) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(FilterCollection.self, from: data) {
            collection = saved
        }
    }

    var filters: [SavedFilter] {
        lock.lock()
        defer { lock.unlock() }
        return collection.filters
    }

    private func change<T>(_ work: (inout FilterCollection) -> T) -> T {
        lock.lock()
        let result = work(&collection)
        let snapshot = collection
        lock.unlock()
        if let file, let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: file, options: .atomic) }
        onChange?()
        return result
    }

    func named(_ name: String) -> SavedFilter? {
        lock.lock()
        defer { lock.unlock() }
        return collection.named(name)
    }

    @discardableResult
    func save(name: String, look: Look) -> Bool {
        change { $0.save(name: name, look: look, id: UUID().uuidString, now: Date()) != nil }
    }

    /// Where a style's picture is kept: the edit or reference it was learned from.
    func pictureURL(_ id: String) -> URL? {
        file?.deletingLastPathComponent().appending(path: "styles", directoryHint: .isDirectory).appending(path: "\(id).jpg")
    }

    /// Saves a style learned from pictures, with a small copy of the picture for the library.
    func saveStyle(name: String, look: Look, fit: LookFit?, match: StyleFingerprint?, picture: Data?) -> SavedFilter? {
        let saved = change { $0.save(name: name, look: look, fit: fit, match: match, id: UUID().uuidString, now: Date()) }
        if let saved, let picture, let url = pictureURL(saved.id) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? picture.write(to: url, options: .atomic)
        }
        return saved
    }

    func rename(id: String, to name: String) -> Bool {
        change { $0.rename(id: id, to: name) }
    }

    func delete(id: String) {
        change { $0.delete(id: id) }
        if let url = pictureURL(id) { try? FileManager.default.removeItem(at: url) }
    }

    func delete(named name: String) -> Bool {
        guard let filter = named(name) else { return false }
        delete(id: filter.id)
        return true
    }
}
