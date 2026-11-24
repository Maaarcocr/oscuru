import CoreGraphics
import Foundation
import OscuruCore
import OscuruEngine
import OscuruScripting

/// Renders one open photo with the engine: for the screen, for measuring, and for the model.
/// Also what scripts see of the app (`ScriptHost`). Usable from any thread.
final class PhotoRenderer: ScriptHost, @unchecked Sendable {
    let engine: Engine
    /// The id the photo is open under in the engine.
    let id: String
    let info: PhotoInfo
    let filters: FilterStore

    init(engine: Engine, id: String, info: PhotoInfo, filters: FilterStore) {
        self.engine = engine
        self.id = id
        self.info = info
        self.filters = filters
    }

    private func recipe(_ state: EditingState) -> RenderRecipe { RenderRecipe(state: state, defaults: info.defaults) }

    /// The photo as opened, framed like `state`, for comparing before and after.
    func original(framedLike state: EditingState) -> EditingState {
        var original = EditingState(defaults: info.defaults)
        original.crop = state.crop
        return original
    }

    func screenImage(of state: EditingState) throws -> CGImage {
        try engine.image(id: id, recipe: recipe(state), options: RenderOptions(maxEdge: 2048))
    }

    /// The photo for the conversation: sharp on any iPhone at the width of the screen.
    func cardImage(of state: EditingState) throws -> CGImage {
        try engine.image(id: id, recipe: recipe(state), options: RenderOptions(maxEdge: 1400))
    }

    func thumbnail(of state: EditingState, maxEdge: Double = 480) -> Data? {
        try? engine.jpeg(id: id, recipe: recipe(state), options: RenderOptions(maxEdge: maxEdge), quality: 0.8)
    }

    func export(_ state: EditingState, format: ExportFormat, to url: URL) throws {
        _ = try engine.export(id: id, recipe: recipe(state), format: format, to: url)
    }

    // MARK: ScriptHost

    func analysis(of state: EditingState) -> ImageAnalysis? {
        guard let bitmap = try? engine.bitmap(id: id, recipe: recipe(state)) else { return nil }
        return ImageAnalysis(pixels: bitmap.pixels, width: bitmap.width, height: bitmap.height)
    }

    func image(of state: EditingState, region: ScriptRegion?, maxEdge: Int) -> Data? {
        let rect = region.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        return try? engine.jpeg(id: id, recipe: recipe(state), options: RenderOptions(maxEdge: Double(maxEdge), region: rect))
    }

    func maskImage(of state: EditingState, mask: Mask, region: ScriptRegion?, maxEdge: Int) -> (jpeg: Data, coverage: Double)? {
        let rect = region.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        return try? engine.maskPreview(id: id, recipe: recipe(state), mask: mask, options: RenderOptions(maxEdge: Double(maxEdge), region: rect))
    }

    // MARK: Attached pictures

    private let referenceLock = NSLock()
    /// The pictures attached to the current instruction, open in the engine under their own ids.
    private var referenceSessions: [(engineID: String, info: ReferenceInfo)] = []

    /// Opens the pictures attached to an instruction in place of the previous ones.
    func setReferences(_ files: [(url: URL, name: String)]) {
        closeReferences()
        var opened: [(engineID: String, info: ReferenceInfo)] = []
        for (index, file) in files.enumerated() {
            let engineID = "\(id)-reference-\(index)-\(UUID().uuidString.prefix(6))"
            guard let info = try? engine.open(id: engineID, url: file.url) else { continue }
            opened.append((engineID, ReferenceInfo(fileName: file.name, isRaw: info.isRaw, width: info.width, height: info.height)))
        }
        referenceLock.withLock { referenceSessions = opened }
    }

    func closeReferences() {
        let previous = referenceLock.withLock {
            let sessions = referenceSessions
            referenceSessions = []
            return sessions
        }
        for session in previous { engine.close(id: session.engineID) }
    }

    private func referenceSession(_ index: Int) -> String? {
        referenceLock.withLock { index >= 0 && index < referenceSessions.count ? referenceSessions[index].engineID : nil }
    }

    func references() -> [ReferenceInfo] { referenceLock.withLock { referenceSessions.map(\.info) } }

    /// An attached picture as an sRGB JPEG for the model, a RAW one developed the neutral way.
    func referenceImage(_ index: Int, maxEdge: Int) -> Data? {
        guard let session = referenceSession(index) else { return nil }
        return try? engine.jpeg(id: session, recipe: RenderRecipe(), options: RenderOptions(maxEdge: Double(maxEdge)))
    }

    func pixels(ofReference index: Int) -> PixelBuffer? {
        guard let session = referenceSession(index) else { return nil }
        return try? engine.displayPixels(id: session, recipe: RenderRecipe())
    }

    func pixels(of state: EditingState) -> PixelBuffer? {
        try? engine.displayPixels(id: id, recipe: recipe(state))
    }

    func referenceAnalysis(_ index: Int) -> ImageAnalysis? {
        guard let session = referenceSession(index), let bitmap = try? engine.bitmap(id: session, recipe: RenderRecipe()) else { return nil }
        return ImageAnalysis(pixels: bitmap.pixels, width: bitmap.width, height: bitmap.height)
    }

    func filterNames() -> [String] { filters.filters.map(\.name) }
    func look(named name: String) -> Look? { filters.named(name)?.look }
    func saveFilter(name: String, look: Look) -> Bool { filters.save(name: name, look: look) }
    func deleteFilter(name: String) -> Bool { filters.delete(named: name) }
}
