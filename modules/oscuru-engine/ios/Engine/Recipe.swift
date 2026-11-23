import Foundation

/// What to render: filter amounts plus the tone and colour tables.
/// Built by `src/engine/recipe.ts`; the meaning of every field is documented there.
public struct RenderRecipe {
  public struct LocalContrastPass {
    public var radius: Double
    public var intensity: Double
    public init(radius: Double, intensity: Double) {
      self.radius = radius
      self.intensity = intensity
    }
  }

  public var exposureEV: Double = 0
  public var temperature: Double?
  public var tint: Double?
  public var shadowAmount: Double = 0
  public var highlightAmount: Double = 1
  public var localContrast: [LocalContrastPass] = []
  public var sharpening: Double?
  public var noiseReduction: Double?
  public var colorNoiseReduction: Double?
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

  public init(dictionary: [String: Any], toneTable: Data, cube: Data) {
    func number(_ key: String) -> Double? {
      (dictionary[key] as? NSNumber)?.doubleValue
    }
    func flag(_ key: String) -> Bool {
      (dictionary[key] as? NSNumber)?.boolValue ?? false
    }
    exposureEV = number("exposureEV") ?? 0
    temperature = number("temperature")
    tint = number("tint")
    shadowAmount = number("shadowAmount") ?? 0
    highlightAmount = number("highlightAmount") ?? 1
    if let passes = dictionary["localContrast"] as? [[String: Any]] {
      localContrast = passes.compactMap { pass in
        guard let radius = (pass["radius"] as? NSNumber)?.doubleValue,
          let intensity = (pass["intensity"] as? NSNumber)?.doubleValue
        else { return nil }
        return LocalContrastPass(radius: radius, intensity: intensity)
      }
    }
    sharpening = number("sharpening")
    noiseReduction = number("noiseReduction")
    colorNoiseReduction = number("colorNoiseReduction")
    vignette = number("vignette") ?? 0
    rotation = Int(number("rotation") ?? 0)
    flipHorizontal = flag("flipHorizontal")
    flipVertical = flag("flipVertical")
    angle = number("angle") ?? 0
    cropX = number("cropX") ?? 0
    cropY = number("cropY") ?? 0
    cropWidth = number("cropWidth") ?? 1
    cropHeight = number("cropHeight") ?? 1
    toneTableSize = Int(number("toneTableSize") ?? 0)
    cubeSize = Int(number("cubeSize") ?? 0)
    self.toneTable = toneTable
    self.cube = cube
  }
}

public struct RenderOptions {
  /// Long edge of the output in pixels. 0 renders at full resolution.
  public var maxEdge: Double = 0
  /// "jpeg" or "heic".
  public var format: String = "jpeg"
  public var quality: Double = 0.9
  /// "p3" or "srgb".
  public var colorSpace: String = "p3"
  /// Long edge of the sRGB bitmap returned for statistics. 0 for none.
  public var statsEdge: Int = 0
  /// Ignore the crop rectangle and vignette (the crop tool shows the whole frame).
  public var fullFrame = false
  /// Each slot keeps one file per photo: writing a new one removes the previous.
  public var slot: String = "preview"

  public init() {}

  public init(dictionary: [String: Any]) {
    maxEdge = (dictionary["maxEdge"] as? NSNumber)?.doubleValue ?? 0
    format = dictionary["format"] as? String ?? "jpeg"
    quality = (dictionary["quality"] as? NSNumber)?.doubleValue ?? 0.9
    colorSpace = dictionary["colorSpace"] as? String ?? "p3"
    statsEdge = (dictionary["statsEdge"] as? NSNumber)?.intValue ?? 0
    fullFrame = (dictionary["fullFrame"] as? NSNumber)?.boolValue ?? false
    slot = dictionary["slot"] as? String ?? "preview"
  }
}

public struct RenderResult {
  public var url: URL
  public var width: Int
  public var height: Int
  public var statsWidth: Int = 0
  public var statsHeight: Int = 0
  /// sRGB RGBA8, top row first.
  public var statsPixels = Data()
}

public enum EngineError: Error, CustomStringConvertible {
  case cannotOpen(String)
  case unknownSession(String)
  case renderFailed(String)

  public var code: String {
    switch self {
    case .cannotOpen: return "ERR_CANNOT_OPEN"
    case .unknownSession: return "ERR_UNKNOWN_SESSION"
    case .renderFailed: return "ERR_RENDER_FAILED"
    }
  }

  public var description: String {
    switch self {
    case .cannotOpen(let detail): return "Cannot open this photo: \(detail)"
    case .unknownSession(let id): return "No open photo with id \(id)"
    case .renderFailed(let detail): return "Rendering failed: \(detail)"
    }
  }
}
