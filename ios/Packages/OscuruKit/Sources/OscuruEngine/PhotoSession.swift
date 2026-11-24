import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import OscuruCore
import UniformTypeIdentifiers

/// One opened photo. The original file is only ever read.
///
/// Not thread-safe: `Engine` uses each session from one queue.
public final class PhotoSession {
  public let url: URL
  public let isRaw: Bool
  /// Full-resolution size after the file's own orientation is applied.
  public let size: CGSize
  public private(set) var info = PhotoInfo(fileName: "", typeIdentifier: "", isRaw: false, width: 0, height: 0)
  /// Image properties (EXIF and friends) to carry into exports.
  public let properties: [String: Any]

  private let rawFilter: CIRAWFilter?
  private let rawDefaults: (temperature: Float, tint: Float, sharpness: Float, luminanceNoise: Float, colorNoise: Float)
  private let fullImage: CIImage?
  private let previewImage: CIImage?

  /// The developed RAW at preview size, kept so that later stages can change without decoding again.
  private var developedCache: (key: String, image: CIImage)?
  /// What Vision found in the photo ("subject", "people"), searched for once each.
  private var found: [String: CIImage] = [:]
  private var searched: Set<String> = []
  /// The photo as Vision sees it: developed as opened, small.
  private var analysisPicture: CGImage?
  /// The segmentation model's reading of the photo as framed (`key`), kept for further selections.
  private var selectionEncoding: (key: String, encoding: Segmenter.Encoding)?
  /// Objects selected so far, by framing and points.
  private var selections: [String: Segmenter.Logits] = [:]

  private static let previewLongEdge: CGFloat = 2560
  private static let rawExtensions: Set<String> = [
    "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef", "srw", "3fr", "erf", "mos", "mrw", "x3f", "iiq", "gpr", "raw",
  ]

  public init(url: URL) throws {
    self.url = url
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
      throw EngineError.cannotOpen("the file is not an image")
    }
    let typeIdentifier = CGImageSourceGetType(source) as String? ?? ""
    let fileProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
    properties = fileProperties

    let conformsToRaw = UTType(typeIdentifier)?.conforms(to: .rawImage) ?? false
    let looksRaw = conformsToRaw || PhotoSession.rawExtensions.contains(url.pathExtension.lowercased())

    if looksRaw, let filter = CIRAWFilter(imageURL: url), let output = filter.outputImage {
      isRaw = true
      rawFilter = filter
      PhotoSession.neutralize(filter)
      // White balance starts as shot. Noise reduction and sharpening start at zero: Oscuru adds
      // nothing the person or the assistant did not ask for.
      rawDefaults = (filter.neutralTemperature, filter.neutralTint, 0, 0, 0)
      size = output.extent.size
      fullImage = nil
      previewImage = nil
    } else {
      isRaw = false
      rawFilter = nil
      rawDefaults = (6500, 0, 0, 0, 0)
      guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
        throw EngineError.cannotOpen("the format is not supported")
      }
      fullImage = image
      size = image.extent.size
      let thumbnailOptions: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: PhotoSession.previewLongEdge,
        kCGImageSourceShouldCacheImmediately: true,
      ]
      if max(size.width, size.height) > PhotoSession.previewLongEdge,
        let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
      {
        previewImage = CIImage(cgImage: thumbnail)
      } else {
        previewImage = nil
      }
    }
    guard size.width >= 1, size.height >= 1, size.width.isFinite, size.height.isFinite else {
      throw EngineError.cannotOpen("the image is empty")
    }
    info = PhotoSession.describe(
      url: url, typeIdentifier: typeIdentifier, properties: fileProperties, isRaw: isRaw, size: size, defaults: rawDefaults)
  }

  /// The photo after exposure, white balance, noise reduction and (for RAW) sharpening, scaled so that
  /// its size is about `scale` times the full size, with its extent starting at the origin.
  func developed(recipe: RenderRecipe, scale: CGFloat, cache: Bool, context: CIContext) throws -> CIImage {
    if let filter = rawFilter {
      // Cached previews are developed once at a fixed size and scaled down from there, so renders of
      // different sizes (screen, statistics, the model's pictures) share one decode.
      let baseScale = min(1, Engine.previewEdge / max(size.width, size.height))
      let developScale = cache ? max(scale, baseScale) : scale
      let key = [
        Double(developScale), recipe.exposureEV, recipe.temperature ?? -1, recipe.tint ?? -1000, recipe.sharpening ?? -1,
        recipe.noiseReduction ?? -1, recipe.colorNoiseReduction ?? -1,
      ].map { String($0) }.joined(separator: "|")
      var image: CIImage
      if cache, let cached = developedCache, cached.key == key {
        image = cached.image
      } else {
        filter.scaleFactor = Float(min(1, developScale))
        filter.exposure = Float(recipe.exposureEV)
        filter.neutralTemperature = Float(recipe.temperature ?? Double(rawDefaults.temperature))
        filter.neutralTint = Float(recipe.tint ?? Double(rawDefaults.tint))
        if filter.isSharpnessSupported {
          filter.sharpnessAmount = Float(recipe.sharpening ?? Double(rawDefaults.sharpness))
        }
        if filter.isLuminanceNoiseReductionSupported {
          filter.luminanceNoiseReductionAmount = Float(recipe.noiseReduction ?? Double(rawDefaults.luminanceNoise))
        }
        if filter.isColorNoiseReductionSupported {
          filter.colorNoiseReductionAmount = Float(recipe.colorNoiseReduction ?? Double(rawDefaults.colorNoise))
        }
        guard let output = filter.outputImage else {
          throw EngineError.renderFailed("the RAW decoder produced no image")
        }
        image = PhotoSession.applyBaseCurve(to: output.atOrigin())
        if cache {
          image = try PhotoSession.bake(image, context: context)
          developedCache = (key, image)
        }
      }
      let factor = scale / developScale
      if factor < 0.999 {
        let resize = CIFilter.lanczosScaleTransform()
        resize.inputImage = image
        resize.scale = Float(factor)
        resize.aspectRatio = 1
        image = (resize.outputImage ?? image).atOrigin()
      }
      return image
    }

    guard let full = fullImage else {
      throw EngineError.renderFailed("the photo has no image data")
    }
    var image = full
    if let preview = previewImage, scale * max(size.width, size.height) <= max(preview.extent.width, preview.extent.height) {
      image = preview
    }
    let factor = scale * max(size.width, size.height) / max(image.extent.width, image.extent.height)
    if factor < 0.999 {
      let resize = CIFilter.lanczosScaleTransform()
      resize.inputImage = image
      resize.scale = Float(factor)
      resize.aspectRatio = 1
      image = (resize.outputImage ?? image).atOrigin()
    }
    if recipe.exposureEV != 0 {
      let exposure = CIFilter.exposureAdjust()
      exposure.inputImage = image
      exposure.ev = Float(recipe.exposureEV)
      image = exposure.outputImage ?? image
    }
    if let temperature = recipe.temperature {
      // The photo is taken to be balanced for 6500 K. Declaring its white point to be `temperature`
      // and adapting back to 6500 K warms it for higher values, as Camera Raw's slider does.
      let balance = CIFilter.temperatureAndTint()
      balance.inputImage = image
      balance.neutral = CIVector(x: CGFloat(temperature), y: CGFloat(recipe.tint ?? 0))
      balance.targetNeutral = CIVector(x: 6500, y: 0)
      image = balance.outputImage ?? image
    }
    if let amount = recipe.noiseReduction, amount > 0 {
      let denoise = CIFilter.noiseReduction()
      denoise.inputImage = image.clampedToExtent()
      denoise.noiseLevel = Float(amount * 0.06)
      denoise.sharpness = 0.4
      image = (denoise.outputImage ?? image).cropped(to: image.extent)
    }
    if let amount = recipe.sharpening, amount > 0 {
      let sharpen = CIFilter.sharpenLuminance()
      sharpen.inputImage = image.clampedToExtent()
      sharpen.sharpness = Float(amount * 1.5)
      sharpen.radius = Float(max(0.5, 0.0004 * max(image.extent.width, image.extent.height)))
      image = (sharpen.outputImage ?? image).cropped(to: image.extent)
    }
    return image
  }

  /// The subject or people Vision finds in the photo, as a grey mask covering `extent` (the
  /// developed photo at the size being rendered). Nil when there is nothing of that kind.
  func foundMask(_ kind: String, extent: CGRect, context: CIContext) -> CIImage? {
    if !searched.contains(kind) {
      searched.insert(kind)
      if let picture = analysisImage(context: context) {
        found[kind] = kind == "people" ? Effects.findPeople(in: picture) : Effects.findSubject(in: picture)
      }
    }
    guard let mask = found[kind] else { return nil }
    let size = mask.extent.size
    let transform = CGAffineTransform(scaleX: extent.width / size.width, y: extent.height / size.height)
      .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY))
    return mask.transformed(by: transform).cropped(to: extent)
  }

  /// The object at `points` (without what is at `exclude`) in the photo framed as `framing` says,
  /// as the model's logits. The picture is read once per framing; each selection is kept. Nil when
  /// the model cannot run.
  func selection(points: [[Double]], exclude: [[Double]], framing: String, segmenter: Segmenter, picture: () -> CGImage?) -> Segmenter.Logits? {
    let key = "\(framing)|\(points)|\(exclude)"
    if let logits = selections[key] { return logits }
    let encoding: Segmenter.Encoding
    if let saved = selectionEncoding, saved.key == framing {
      encoding = saved.encoding
    } else {
      guard let image = picture(), let encoded = try? segmenter.encode(image) else { return nil }
      selectionEncoding = (framing, encoded)
      encoding = encoded
    }
    guard let logits = try? segmenter.select(encoding, points: points, exclude: exclude) else { return nil }
    if selections.count > 32 { selections.removeAll() }
    selections[key] = logits
    return logits
  }

  func analysisImage(context: CIContext) -> CGImage? {
    if let analysisPicture { return analysisPicture }
    let scale = min(1, 1024 / max(size.width, size.height))
    guard let image = try? developed(recipe: RenderRecipe(), scale: scale, cache: false, context: context),
      let space = CGColorSpace(name: CGColorSpace.sRGB)
    else { return nil }
    analysisPicture = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: space)
    return analysisPicture
  }

  /// Leaves Apple's decoder only what the file's own numbers decide: demosaicing, the camera's
  /// colour matrix and white balance, the lens corrections the file carries, and fitting colours
  /// into range. Its looks are off: no tone curve, no local tone mapping, no noise reduction, no
  /// sharpening. What comes out is linear light, as the sensor measured it.
  private static func neutralize(_ filter: CIRAWFilter) {
    filter.boostAmount = 0
    if filter.isLocalToneMapSupported { filter.localToneMapAmount = 0 }
    if filter.isSharpnessSupported { filter.sharpnessAmount = 0 }
    if filter.isLuminanceNoiseReductionSupported { filter.luminanceNoiseReductionAmount = 0 }
    if filter.isColorNoiseReductionSupported { filter.colorNoiseReductionAmount = 0 }
  }

  private static let baseCurveTable: Data = ColorPipeline.baseCurveTable().withUnsafeBufferPointer { Data(buffer: $0) }

  /// Oscuru's base curve (`ColorPipeline.baseCurve`): the light as measured, with only the
  /// brightest highlights rolled off towards white.
  static func applyBaseCurve(to image: CIImage) -> CIImage {
    guard let space = CGColorSpace(name: CGColorSpace.extendedDisplayP3) else { return image }
    let filter = CIFilter.colorCurves()
    filter.inputImage = image
    filter.curvesData = baseCurveTable
    filter.curvesDomain = CIVector(x: 0, y: CGFloat(ColorPipeline.baseCurveDomain))
    filter.colorSpace = space
    return filter.outputImage ?? image
  }

  /// Renders to a half-float bitmap in extended linear sRGB, so highlights above white survive.
  private static func bake(_ image: CIImage, context: CIContext) throws -> CIImage {
    let width = Int(image.extent.width.rounded(.down))
    let height = Int(image.extent.height.rounded(.down))
    guard width > 0, height > 0, let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else {
      throw EngineError.renderFailed("the developed image is empty")
    }
    let rowBytes = width * 8
    var data = Data(count: rowBytes * height)
    data.withUnsafeMutableBytes { buffer in
      if let base = buffer.baseAddress {
        context.render(
          image, toBitmap: base, rowBytes: rowBytes, bounds: CGRect(x: 0, y: 0, width: width, height: height),
          format: .RGBAh, colorSpace: colorSpace)
      }
    }
    return CIImage(
      bitmapData: data, bytesPerRow: rowBytes, size: CGSize(width: width, height: height), format: .RGBAh,
      colorSpace: colorSpace)
  }

  private static func describe(
    url: URL, typeIdentifier: String, properties: [String: Any], isRaw: Bool, size: CGSize,
    defaults: (temperature: Float, tint: Float, sharpness: Float, luminanceNoise: Float, colorNoise: Float)
  ) -> PhotoInfo {
    let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
    let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
    var info = PhotoInfo(
      fileName: url.lastPathComponent, typeIdentifier: typeIdentifier, isRaw: isRaw, width: Int(size.width.rounded()), height: Int(size.height.rounded()),
      defaults: PhotoDefaults(
        temperature: Double(defaults.temperature), tint: Double(defaults.tint), sharpening: Double(defaults.sharpness) * 100,
        noiseReduction: Double(defaults.luminanceNoise) * 100, colorNoiseReduction: Double(defaults.colorNoise) * 100))
    func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
    info.make = tiff[kCGImagePropertyTIFFMake as String] as? String
    info.model = tiff[kCGImagePropertyTIFFModel as String] as? String
    info.lens = exif[kCGImagePropertyExifLensModel as String] as? String
    info.iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue
    info.exposureTime = number(exif[kCGImagePropertyExifExposureTime as String])
    info.aperture = number(exif[kCGImagePropertyExifFNumber as String])
    info.focalLength = number(exif[kCGImagePropertyExifFocalLength as String])
    info.focalLength35mm = number(exif[kCGImagePropertyExifFocalLenIn35mmFilm as String])
    info.dateTaken = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String
    return info
  }
}

extension CIImage {
  /// The same image moved so that its extent starts at (0, 0).
  func atOrigin() -> CIImage {
    let origin = extent.origin
    if origin == .zero { return self }
    return transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
  }
}
