import CoreGraphics
import Foundation
import OscuruCore
import OscuruEngine
import OscuruScripting

/// One photo open in the engine: every picture of it the app shows, saves or sends comes from
/// here, and so does what scripts see of the app (`ScriptHost`). Usable from any thread.
final class PhotoRenderer: ScriptHost, @unchecked Sendable {
    let engine: Engine
    /// The id the photo is open under in the engine.
    let id: String
    let info: PhotoInfo
    let styles: StyleStore

    /// Long edges, in pixels: filling the screen, in the thread, in the library, on a style's tile.
    static let screenEdge = 2048.0
    static let cardEdge = 1400.0
    static let thumbnailEdge = 480.0
    static let styleEdge = 360.0

    init(engine: Engine, id: String, info: PhotoInfo, styles: StyleStore) {
        self.engine = engine
        self.id = id
        self.info = info
        self.styles = styles
    }

    /// Opens a file for as long as `work` runs: a renderer for a photo no editor has open.
    static func with<T>(_ url: URL, engine: Engine, styles: StyleStore, _ work: (PhotoRenderer) throws -> T) throws -> T {
        try engine.with(url) { id, info in try work(PhotoRenderer(engine: engine, id: id, info: info, styles: styles)) }
    }

    private func recipe(_ state: EditingState) -> RenderRecipe { RenderRecipe(state: state, defaults: info.defaults) }

    /// The photo as opened.
    var original: EditingState { EditingState(defaults: info.defaults) }

    /// The photo as opened, framed like `state`, for comparing before and after.
    func original(framedLike state: EditingState) -> EditingState {
        var original = original
        original.crop = state.crop
        return original
    }

    /// The photo with these settings, for the screen.
    func picture(of state: EditingState, edge: Double) throws -> CGImage {
        try engine.image(id: id, recipe: recipe(state), options: RenderOptions(maxEdge: edge))
    }

    /// The photo with these settings as a small JPEG, to keep: a library thumbnail, a style's picture.
    func jpeg(of state: EditingState, edge: Double) -> Data? {
        try? engine.jpeg(id: id, recipe: recipe(state), options: RenderOptions(maxEdge: edge), quality: 0.8)
    }

    /// Develops the photo at full resolution into a JPEG file.
    func export(_ state: EditingState, to url: URL) throws {
        _ = try engine.export(id: id, recipe: recipe(state), to: url)
    }

    /// The photo's settings with a style in place.
    func apply(_ style: Style, to state: EditingState) throws -> EditingState {
        try style.applied(to: state, defaults: info.defaults, render: pixels(of:))
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

    func pixels(of state: EditingState) -> PixelBuffer? {
        try? engine.displayPixels(id: id, recipe: recipe(state))
    }

    func styleNames() -> [String] { styles.styles.map(\.name) }
    func style(named name: String) -> Style? { styles.named(name) }

    /// The one way a photo's look becomes a style, for the person and the assistant alike.
    func saveStyle(name: String, state: EditingState) -> Bool {
        styles.save(name: name, recipe: .look(Look(state: state, defaults: info.defaults)), picture: jpeg(of: state, edge: PhotoRenderer.styleEdge)) != nil
    }

    func deleteStyle(name: String) -> Bool {
        guard let style = styles.named(name) else { return false }
        styles.delete(id: style.id)
        return true
    }
}
