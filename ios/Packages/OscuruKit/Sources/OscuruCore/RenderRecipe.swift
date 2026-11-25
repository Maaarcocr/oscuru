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

    /// Film grain, added last, on the finished frame.
    public struct Grain: Equatable, Sendable {
        /// Standard deviation of the grain in encoded values at mid-grey.
        public var strength: Double
        /// Size of a grain as a fraction of the frame's long edge, so previews match exports.
        public var size: Double
        /// 0 even to 1 clumpy: how much of a coarser layer is mixed in.
        public var roughness: Double

        public init(strength: Double, size: Double, roughness: Double) {
            self.strength = strength
            self.size = size
            self.roughness = roughness
        }
    }

    /// A glow around bright areas, after the colour stage.
    public struct Halation: Equatable, Sendable {
        /// How much of the glow is screened onto the photo.
        public var strength: Double
        /// Blur radius as a fraction of the photo's long edge.
        public var radius: Double
        /// Linear light level where the glow starts.
        public var threshold: Double
        /// The glow's colour, linear RGB.
        public var color: [Double]

        public init(strength: Double, radius: Double, threshold: Double, color: [Double]) {
            self.strength = strength
            self.radius = radius
            self.threshold = threshold
            self.color = color
        }
    }

    /// One local adjustment, ready to render: what to change, and where.
    public struct LocalPass: Equatable, Sendable {
        public var mask: Mask
        /// Float32 RGB triples in encoded Display P3, `toneTableSize` of them; empty for no tone change.
        public var toneTable = Data()
        public var toneTableSize = 0
        /// Linear RGB gains, or nil for no white balance change.
        public var gains: [Double]?
        /// 1 is unchanged.
        public var saturation: Double = 1
        /// Unsharp-mask intensity at the clarity radius; 0 for none.
        public var clarity: Double = 0

        public init(mask: Mask) {
            self.mask = mask
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
    /// A collage's arrangement; nil for a photo.
    public var layout: CollageLayout?
    public var toneTableSize: Int = 0
    public var cubeSize: Int = 0
    /// Float32 RGB triples, `toneTableSize` of them. Empty for no tone stage.
    public var toneTable = Data()
    /// Float32 RGBA, `cubeSize`³ entries, red fastest. Empty for no colour stage.
    public var cube = Data()
    public var halation: Halation?
    public var local: [LocalPass] = []
    public var grain: Grain?

    /// The radius of the clarity pass, as a fraction of the photo's long edge.
    public static let clarityRadius = 0.02

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
        if state.value("clarity") != 0 { localContrast.append(.init(radius: RenderRecipe.clarityRadius, intensity: state.value("clarity") / 100 * 0.7)) }
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
        layout = state.layout
        if let table = ColorPipeline.toneTables(state) {
            toneTableSize = ColorPipeline.toneTableSize
            toneTable = table.withUnsafeBufferPointer { Data(buffer: $0) }
        }
        if let table = ColorPipeline.colorCube(state) {
            cubeSize = ColorPipeline.cubeSize
            cube = table.withUnsafeBufferPointer { Data(buffer: $0) }
        }
        let halationAmount = state.halation["amount"] ?? 0
        if halationAmount > 0 {
            let threshold = 0.5 + (state.halation["threshold"] ?? 70) / 100 * 0.45
            halation = Halation(
                strength: halationAmount / 100 * 0.8, radius: 0.003 + (state.halation["radius"] ?? 30) / 100 * 0.03,
                threshold: ColorPipeline.decode(threshold), color: [1, 0.22, 0.06])
        }
        for adjustment in state.local where !adjustment.isIdentity {
            let adjust = adjustment.adjust
            var pass = LocalPass(mask: adjustment.mask)
            if let table = ColorPipeline.localToneTable(adjust) {
                pass.toneTableSize = ColorPipeline.toneTableSize
                pass.toneTable = table.withUnsafeBufferPointer { Data(buffer: $0) }
            }
            let temperature = adjust["temperature"] ?? 0
            let tint = adjust["tint"] ?? 0
            if temperature != 0 || tint != 0 { pass.gains = ColorPipeline.whiteBalanceGains(temperature: temperature, tint: tint) }
            pass.saturation = 1 + (adjust["saturation"] ?? 0) / 100
            pass.clarity = (adjust["clarity"] ?? 0) / 100 * 0.7
            local.append(pass)
        }
        let grainAmount = state.grain["amount"] ?? 0
        if grainAmount > 0 {
            let size = (state.grain["size"] ?? 25) / 100
            grain = Grain(strength: grainAmount / 100 * 0.12, size: 0.00025 + pow(size, 1.5) * 0.0025, roughness: (state.grain["roughness"] ?? 50) / 100)
        }
    }
}
