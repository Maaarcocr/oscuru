import Foundation

/// What the engine needs to render a state: plain filter amounts plus the tone and colour tables.
/// All the mapping from photographic settings to filter amounts lives in `init(state:defaults:)`,
/// so it is tested without a phone; the engine only applies what it is given.
public struct RenderRecipe: Equatable, Sendable {
    public struct LocalContrastPass: Equatable, Sendable {
        /// Blur radius as a fraction of the photo's long edge, so previews match exports.
        public var radius: Double
        /// Unsharp-mask intensity. Negative softens.
        public var intensity: Double

        public init(radius: Double, intensity: Double) {
            self.radius = radius
            self.intensity = intensity
        }
    }

    public var exposureEV: Double = 0
    /// White balance, or nil to leave the photo as shot.
    public var temperature: Double?
    public var tint: Double?
    /// Local shadow lift, 0 (off) to 1.
    public var shadowAmount: Double = 0
    /// Local highlight recovery, 1 (off) down to 0.
    public var highlightAmount: Double = 1
    public var localContrast: [LocalContrastPass] = []
    /// 0–1. Nil leaves the RAW decoder's default.
    public var sharpening: Double?
    public var noiseReduction: Double?
    public var colorNoiseReduction: Double?
    /// −1 (lighten corners) to 1 (darken corners).
    public var vignette: Double = 0
    public var rotation: Int = 0
    public var flipHorizontal = false
    public var flipVertical = false
    public var angle: Double = 0
    public var cropX: Double = 0
    public var cropY: Double = 0
    public var cropWidth: Double = 1
    public var cropHeight: Double = 1
    public var toneTableSize: Int = 0
    public var cubeSize: Int = 0
    /// Float32 RGB triples, `toneTableSize` of them. Empty for no tone stage.
    public var toneTable = Data()
    /// Float32 RGBA, `cubeSize`³ entries, red fastest. Empty for no colour stage.
    public var cube = Data()

    public init() {}

    public init(state: EditingState, defaults: PhotoDefaults) {
        let base = EditingState(defaults: defaults)
        exposureEV = state.value("exposureEV")
        if state.value("temperature") != base.value("temperature") || state.value("tint") != base.value("tint") {
            temperature = state.value("temperature")
            tint = state.value("tint")
        }
        shadowAmount = state.value("shadows") > 0 ? state.value("shadows") / 100 * 0.8 : 0
        highlightAmount = state.value("highlights") < 0 ? 1 + state.value("highlights") / 100 * 0.7 : 1
        if state.value("clarity") != 0 { localContrast.append(.init(radius: 0.02, intensity: state.value("clarity") / 100 * 0.7)) }
        if state.value("texture") != 0 { localContrast.append(.init(radius: 0.003, intensity: state.value("texture") / 100 * 0.6)) }
        func unlessDefault(_ key: String) -> Double? {
            state.detail[key] == base.detail[key] ? nil : (state.detail[key] ?? 0) / 100
        }
        sharpening = unlessDefault("sharpening")
        noiseReduction = unlessDefault("noiseReduction")
        colorNoiseReduction = unlessDefault("colorNoiseReduction")
        vignette = state.value("vignette") == 0 ? 0 : -state.value("vignette") / 100
        rotation = state.crop.rotation
        flipHorizontal = state.crop.flipHorizontal
        flipVertical = state.crop.flipVertical
        angle = state.crop.angle
        cropX = state.crop.x
        cropY = state.crop.y
        cropWidth = state.crop.width
        cropHeight = state.crop.height
        if let table = ColorPipeline.toneTables(state) {
            toneTableSize = ColorPipeline.toneTableSize
            toneTable = table.withUnsafeBufferPointer { Data(buffer: $0) }
        }
        if let table = ColorPipeline.colorCube(state) {
            cubeSize = ColorPipeline.cubeSize
            cube = table.withUnsafeBufferPointer { Data(buffer: $0) }
        }
    }
}
