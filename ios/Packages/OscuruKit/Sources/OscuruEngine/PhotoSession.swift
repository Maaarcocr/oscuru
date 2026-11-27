import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import OscuruCore
import UniformTypeIdentifiers

/// One opened photo. The original file is only ever read.
///
/// Not thread-safe: `Engine` uses each session only while holding its `lock`.
public final class PhotoSession {
  let lock = NSLock()
  public let url: URL
  public let isRaw: Bool
  /// Full-resolution size after the file's own orientation is applied; for a collage, its canvas in
  /// the arrangement last rendered.
  public private(set) var size: CGSize
  public private(set) var info = PhotoInfo(fileName: "", typeIdentifier: "", isRaw: false, width: 0, height: 0)
  /// Image properties (EXIF and friends) to carry into exports.
  public let properties: [String: Any]

  private let rawDefaults: (temperature: Float, tint: Float, sharpness: Float, luminanceNoise: Float, colorNoise: Float)
  private let fullImage: CIImage?
  private let previewImage: CIImage?
  /// A collage's pieces, at full size and as previews, and how it was first arranged.
  private let collage: (manifest: CollageManifest, full: [CIImage], preview: [CIImage])?
  /// The arrangement last rendered, for a collage.
  private var layout: CollageLayout?

  /// The RAW picture the file itself holds; nil for a photo that is not RAW.
  private var original: RawSource?
  /// The frames of the shot, when the camera kept them beside the file (see `FrameSet`).
  private(set) var frameSet: FrameSet?
  /// RAW pictures the photo is developed from other than its file: one frame alone, or its frames
  /// merged another way than the camera's, by `FrameMerge.Way.key`, the last used last.
  private var sources: [(key: String, source: RawSource)] = []
  private static let maxSources = 3
  /// How many merges other than the camera's are kept as files: older ones are made again when asked for.
  private static let maxMerges = 5
  /// What the kept merges may take together, in bytes.
  private static let mergesRoom = 1_000_000_000
  /// What Vision found in the photo ("subject", "people"), searched for once each.
  private var found: [String: CIImage] = [:]
  private var searched: Set<String> = []
  /// The photo as Vision sees it: developed as opened, small.
  private var analysisPicture: CGImage?
  /// The segmentation model's reading of the photo as framed (`key`), kept for further selections.
  private var selectionEncoding: (key: String, encoding: Segmenter.Encoding)?
  /// Objects selected so far, by framing and points.
  private var selections: [String: Segmenter.Logits] = [:]
  /// How far each part of the photo is, estimated once, on the whole uncropped picture.
  private var depthMap: DepthMap?
  private var estimatedDepth = false

  private static let previewLongEdge: CGFloat = 2560
  /// The largest development kept for previews, on its long edge: a closely cropped photo's
  /// preview develops more of the photo, and kept at that size it would hold hundreds of megabytes
  /// for each photo open. Larger ones are developed for each render instead.
  private static let keptEdge: CGFloat = 3072
  private static let rawExtensions: Set<String> = [
    "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef", "srw", "3fr", "erf", "mos", "mrw", "x3f", "iiq", "gpr", "raw",
  ]

  public init(url: URL) throws {
    self.url = url
    if url.pathExtension.lowercased() == CollageManifest.fileExtension {
      guard let data = try? Data(contentsOf: url), let manifest = try? JSONDecoder().decode(CollageManifest.self, from: data), !manifest.pieces.isEmpty
      else { throw EngineError.cannotOpen("the collage could not be read") }
      var full: [CIImage] = []
      var preview: [CIImage] = []
      for piece in manifest.pieces {
        let file = url.deletingLastPathComponent().appendingPathComponent(piece.file)
        guard let image = CIImage(contentsOf: file, options: [.applyOrientationProperty: true]) else {
          throw EngineError.cannotOpen("a photo in the collage is missing")
        }
        full.append(image.atOrigin())
        preview.append(PhotoSession.preview(of: file, size: image.extent.size) ?? image.atOrigin())
      }
      collage = (manifest, full, preview)
      layout = manifest.layout
      isRaw = false
      rawDefaults = (6500, 0, 0, 0, 0)
      fullImage = nil
      previewImage = nil
      properties = [:]
      let canvas = manifest.layout.canvasSize
      size = CGSize(width: canvas.width, height: canvas.height)
      info = PhotoInfo(
        fileName: url.lastPathComponent, typeIdentifier: "com.oscuru.collage", isRaw: false, width: canvas.width, height: canvas.height,
        defaults: PhotoDefaults(layout: manifest.layout))
      info.pieces = manifest.pieces
      return
    }
    collage = nil
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
      PhotoSession.neutralize(filter)
      // White balance starts as shot. Noise reduction and sharpening start at zero: Oscuru adds
      // nothing the person or the assistant did not ask for.
      rawDefaults = (filter.neutralTemperature, filter.neutralTint, 0, 0, 0)
      size = output.extent.size
      fullImage = nil
      previewImage = nil
      original = RawSource(filter: filter, size: output.extent.size)
    } else {
      isRaw = false
      rawDefaults = (6500, 0, 0, 0, 0)
      guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
        throw EngineError.cannotOpen("the format is not supported")
      }
      fullImage = image
      size = image.extent.size
      previewImage = PhotoSession.preview(of: url, size: size)
    }
    guard size.width >= 1, size.height >= 1, size.width.isFinite, size.height.isFinite else {
      throw EngineError.cannotOpen("the image is empty")
    }
    info = PhotoSession.describe(
      url: url, typeIdentifier: typeIdentifier, properties: fileProperties, isRaw: isRaw, size: size, defaults: rawDefaults)
    // A shot whose frames the camera kept: the file is its own merge of them, and where their merging starts.
    let manifest = url.deletingLastPathComponent().appendingPathComponent(FrameSet.folder).appendingPathComponent(FrameSet.manifest)
    if let original, let data = try? Data(contentsOf: manifest), let set = try? JSONDecoder().decode(FrameSet.self, from: data), !set.frames.isEmpty {
      frameSet = set
      original.brightening = Float(set.brightening(of: set.merge))
      info.frameSet = set
      info.defaults.frames = FrameMerge(way: set.merge)
    }
  }

  /// A smaller copy of a large image file for previews, at most `previewLongEdge` on its long edge;
  /// nil when the file is no larger than that.
  private static func preview(of url: URL, size: CGSize) -> CIImage? {
    guard max(size.width, size.height) > previewLongEdge, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: previewLongEdge,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { CIImage(cgImage: $0) }
  }

  /// Arranges a collage as `layout` says (its first arrangement when nil) before it is rendered. What
  /// was found in the picture (subject, people, objects, depth) belonged to the old arrangement and
  /// is looked for again. Does nothing for a photo.
  func use(_ layout: CollageLayout?) {
    guard let collage else { return }
    let wanted = layout ?? collage.manifest.layout
    guard wanted != self.layout else { return }
    self.layout = wanted
    let canvas = wanted.canvasSize
    size = CGSize(width: canvas.width, height: canvas.height)
    analysisPicture = nil
    found = [:]
    searched = []
    depthMap = nil
    estimatedDepth = false
    selectionEncoding = nil
    selections = [:]
  }

  /// Takes the photo's size from the picture its frames are merged into as `way` says (its file's
  /// when nil) before it is rendered: frames merged onto a finer grid make a photo twice as wide
  /// and high. Every other picture of the photo (another way of merging laid in through a mask) is
  /// developed to this size. Does nothing for a photo without frames.
  func use(frames way: FrameMerge.Way?) {
    guard let original, frameSet != nil else { return }
    let wanted = rawSource(for: way)?.size ?? original.size
    guard wanted != size, wanted.width >= 1, wanted.height >= 1 else { return }
    size = wanted
    info.width = Int(wanted.width.rounded())
    info.height = Int(wanted.height.rounded())
    analysisPicture = nil
  }

  /// The photo after exposure, white balance, noise reduction and (for RAW) sharpening, scaled so that
  /// its size is about `scale` times the full size, with its extent starting at the origin.
  /// A shot's frames are merged as `way` says: the picture's own way (`recipe.frames`) unless another is given.
  func developed(recipe: RenderRecipe, way: FrameMerge.Way? = nil, scale: CGFloat, cache: Bool, context: CIContext) throws -> CIImage {
    if let source = rawSource(for: way ?? recipe.frames?.way) {
      let filter = source.filter
      // Cached previews are developed once at a fixed size and scaled down from there, so renders of
      // different sizes (screen, statistics, the model's pictures) share one decode.
      let baseScale = min(1, Engine.previewEdge / max(size.width, size.height))
      var developScale = cache ? max(scale, baseScale) : scale
      let keep = cache && developScale * max(size.width, size.height) <= PhotoSession.keptEdge
      if !keep { developScale = scale }
      // The source may be smaller or larger than the photo (frames merged onto a finer grid, or
      // the photo's file beside such a merge): it is developed to the photo's size.
      let relative = max(size.width, size.height) / max(source.size.width, source.size.height)
      let key = [
        Double(developScale), Double(size.width), recipe.exposureEV, recipe.temperature ?? -1, recipe.tint ?? -1000, recipe.sharpening ?? -1,
        recipe.noiseReduction ?? -1, recipe.colorNoiseReduction ?? -1,
      ].map { String($0) }.joined(separator: "|")
      var image: CIImage
      if keep, let cached = source.developed, cached.key == key {
        image = cached.image
      } else {
        filter.scaleFactor = Float(min(1, developScale * relative))
        // A merge that holds highlights above its base frame's white sits that much lower in its file.
        filter.exposure = Float(recipe.exposureEV) + source.brightening
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
        if keep {
          image = try PhotoSession.bake(image, context: context)
          source.developed = (key, image)
        }
      }
      // To the size wanted: down from a kept preview's development, or up from a smaller source.
      let factor = scale * max(size.width, size.height) / max(image.extent.width, image.extent.height)
      if abs(factor - 1) > 0.001 {
        let resize = CIFilter.lanczosScaleTransform()
        resize.inputImage = image
        resize.scale = Float(factor)
        resize.aspectRatio = 1
        image = (resize.outputImage ?? image).atOrigin()
      }
      return image
    }

    var image: CIImage
    if let collage {
      // Arranged at the size wanted, from the previews when they are big enough.
      let width = max(1, Int((size.width * scale).rounded()))
      let height = max(1, Int((size.height * scale).rounded()))
      let pieces = CGFloat(max(width, height)) <= PhotoSession.previewLongEdge ? collage.preview : collage.full
      image = Effects.collage(layout ?? collage.manifest.layout, pieces: pieces, width: width, height: height)
    } else {
      guard let full = fullImage else {
        throw EngineError.renderFailed("the photo has no image data")
      }
      image = full
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

  // MARK: Frames

  /// The RAW picture a way of merging the shot's frames gives: the file itself for the camera's own
  /// way (or a photo without frames), one frame's file for that frame alone, otherwise a merge made
  /// now unless it is kept from before. A merge that cannot be made (the frames are gone or cannot
  /// be read) leaves the photo as its file has it.
  private func rawSource(for way: FrameMerge.Way?) -> RawSource? {
    guard let original else { return nil }
    guard let way, let set = frameSet, way.key != set.merge.key else { return original }
    if let index = sources.firstIndex(where: { $0.key == way.key }) {
      let found = sources.remove(at: index)
      sources.append(found)
      return found.source
    }
    guard let file = try? rawFile(for: way, set: set), let filter = CIRAWFilter(imageURL: file), let output = filter.outputImage else { return original }
    PhotoSession.neutralize(filter)
    let source = RawSource(filter: filter, size: output.extent.size, brightening: Float(set.brightening(of: way)))
    sources.append((way.key, source))
    if sources.count > PhotoSession.maxSources { sources.removeFirst() }
    return source
  }

  /// The DNG a way of merging gives, made if it is not there.
  private func rawFile(for way: FrameMerge.Way, set: FrameSet) throws -> URL {
    let folder = url.deletingLastPathComponent()
    let frames = folder.appendingPathComponent(FrameSet.folder)
    func frame(_ number: Int) -> URL { frames.appendingPathComponent(FrameSet.fileName(of: number)) }
    if way.isSingle {
      guard FileManager.default.fileExists(atPath: frame(way.base).path) else { throw EngineError.cannotOpen("frame \(way.base) is not kept") }
      return frame(way.base)
    }
    let merges = folder.appendingPathComponent(FrameSet.mergesFolder)
    // A merge onto a finer grid is named apart: before build 48 one was written as a single strip
    // of hundreds of megabytes, which the RAW decoder crashed on each time the photo was drawn.
    // Such a file is let go and the merge made again.
    let file = merges.appendingPathComponent(way.scale > 1 ? "\(way.key)-strips.dng" : "\(way.key).dng")
    if way.scale > 1 {
      let old = merges.appendingPathComponent("\(way.key).dng")
      try? FileManager.default.removeItem(at: old)
      try? FileManager.default.removeItem(at: old.deletingPathExtension().appendingPathExtension("json"))
    }
    if FileManager.default.fileExists(atPath: file.path) {
      // Used now: the last to be made room for.
      try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
      return file
    }
    guard set.kept else { throw EngineError.cannotOpen("the frames are not kept") }
    let result = try FrameMerging.merge(way, light: set.light) { try DNG.frame(of: Data(contentsOf: frame($0))) }
    // The base frame's own file, with the merged picture in place of its own.
    let base = try Data(contentsOf: frame(way.base))
    let merged: Data
    switch result.merged {
    case .mosaic(let picture): merged = try DNG.replacingFrame(of: base, with: picture.frame)
    case .rgb(let picture, _): merged = try DNG.replacingFrame(of: base, with: picture)
    }
    try FileManager.default.createDirectory(at: merges, withIntermediateDirectories: true)
    try merged.write(to: file, options: .atomic)
    let reports = Dictionary(uniqueKeysWithValues: result.reports.map { (String($0.key), $0.value) })
    try? JSONEncoder().encode(reports).write(to: file.deletingPathExtension().appendingPathExtension("json"), options: .atomic)
    // Room for it: the merges used longest ago go, past a few of them or past what they may take
    // together (one onto a finer grid takes several times a frame's room). The newest stays.
    let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
    let kept = (try? FileManager.default.contentsOfDirectory(at: merges, includingPropertiesForKeys: keys)) ?? []
    let dated = kept.filter { $0.pathExtension == "dng" }.map { url -> (url: URL, date: Date, size: Int) in
      let values = try? url.resourceValues(forKeys: Set(keys))
      return (url, values?.contentModificationDate ?? .distantPast, values?.fileSize ?? 0)
    }
    var room = 0
    for (index, merge) in dated.sorted(by: { $0.date > $1.date }).enumerated() {
      room += merge.size
      guard index > 0, index >= PhotoSession.maxMerges || room > PhotoSession.mergesRoom else { continue }
      try? FileManager.default.removeItem(at: merge.url)
      try? FileManager.default.removeItem(at: merge.url.deletingPathExtension().appendingPathExtension("json"))
    }
    return file
  }

  /// What lining up and merging found of each frame a way uses, by frame number, making the merge
  /// if it is not there. Nil when the photo has no frames or they cannot be merged that way.
  func frameReports(for way: FrameMerge.Way?) -> [Int: FrameReport]? {
    guard let way, let set = frameSet else { return nil }
    if way.key == set.merge.key {
      return Dictionary(uniqueKeysWithValues: set.frames.enumerated().map { ($0.offset + 1, $0.element.report) }.filter { $0.0 != way.base })
    }
    guard let file = try? rawFile(for: way, set: set) else { return nil }
    guard !way.isSingle, let data = try? Data(contentsOf: file.deletingPathExtension().appendingPathExtension("json")),
      let reports = try? JSONDecoder().decode([String: FrameReport].self, from: data)
    else { return [:] }
    return Dictionary(uniqueKeysWithValues: reports.compactMap { key, value in Int(key).map { ($0, value) } })
  }

  // MARK: What is in the picture

  /// The subject or people Vision finds in the photo, as a grey mask covering `extent` (the
  /// developed photo at the size being rendered). Nil when there is nothing of that kind.
  func foundMask(_ kind: String, extent: CGRect, context: CIContext) -> CIImage? {
    // Searched for once there is a picture to search: a picture that could not be drawn is looked
    // for again next time, instead of the photo having no subject from then on.
    if !searched.contains(kind), let picture = analysisImage(context: context) {
      searched.insert(kind)
      found[kind] = kind == "people" ? Effects.findPeople(in: picture) : Effects.findSubject(in: picture)
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

  /// How far each part of the photo is, over the whole picture as opened (before any crop, so a
  /// crop does not change the scale). Nil when the model cannot run.
  func depth(estimator: DepthEstimator, context: CIContext) -> DepthMap? {
    if !estimatedDepth, let picture = analysisImage(context: context) {
      estimatedDepth = true
      depthMap = try? estimator.depth(of: picture)
    }
    return depthMap
  }

  func analysisImage(context: CIContext) -> CGImage? {
    if let analysisPicture { return analysisPicture }
    let scale = min(1, 1024 / max(size.width, size.height))
    guard let image = try? developed(recipe: RenderRecipe(), scale: scale, cache: false, context: context),
      let space = CGColorSpace(name: CGColorSpace.sRGB)
    else { return nil }
    analysisPicture = try? context.picture(of: image, space: space)
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
    try data.withUnsafeMutableBytes { buffer in
      guard let base = buffer.baseAddress else { throw EngineError.renderFailed("there is no room for the developed image") }
      try context.draw(image, into: base, rowBytes: rowBytes, bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAh, colorSpace: colorSpace)
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

/// A RAW picture a photo is developed from: its decoder, how much brighter it is to be shown than
/// its file says (`MergedFrame.brightening`), and its development at preview size, kept so that
/// later stages can change without decoding again.
final class RawSource {
  let filter: CIRAWFilter
  var brightening: Float
  /// Its full size, upright: the sensor's, or twice it for frames merged onto a finer grid.
  let size: CGSize
  var developed: (key: String, image: CIImage)?

  init(filter: CIRAWFilter, size: CGSize, brightening: Float = 0) {
    self.filter = filter
    self.size = size
    self.brightening = brightening
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
