import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import OscuruCore
import UniformTypeIdentifiers

/// Opens photos and renders recipes with Core Image. Safe to call from any thread: calls are
/// carried out one at a time.
///
/// Pipeline, in order: develop (exposure, white balance, noise reduction, in linear light; for RAW
/// files, Apple's decoder with its looks off, then Oscuru's base curve) → local highlight and shadow recovery → local contrast → tone tables → colour cube →
/// halation → flips, rotation, straightening, crop → local adjustments → vignette → grain → output.
public final class Engine: @unchecked Sendable {
  public let context: CIContext
  private let lock = NSLock()
  private var sessions: [String: PhotoSession] = [:]

  /// Tables are defined in gamma-encoded Display P3.
  private let tableColorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
  private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

  /// Renders up to this long edge share one developed image per photo.
  static let previewEdge: Double = 2048

  /// Where the on-device models are (see `Segmenter`, `DepthEstimator`); nil when this build has none.
  private let models: URL?
  /// Loaded on first use; nil when the models are missing or would not load.
  private lazy var segmenter: Segmenter? = models.flatMap { try? Segmenter(folder: $0) }
  private lazy var depthEstimator: DepthEstimator? = models.flatMap { try? DepthEstimator(folder: $0) }

  /// `models` is the folder holding the models that tapping an object and depth ranges need.
  public init(useSoftwareRenderer: Bool = false, models: URL? = nil) {
    self.models = models
    var options: [CIContextOption: Any] = [
      .workingFormat: NSNumber(value: CIFormat.RGBAh.rawValue),
      .cacheIntermediates: true,
    ]
    if let working = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) {
      options[.workingColorSpace] = working
    }
    if useSoftwareRenderer {
      options[.useSoftwareRenderer] = true
    }
    context = CIContext(options: options)
  }

  private func locked<T>(_ work: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try work()
  }

  private func session(_ id: String) throws -> PhotoSession {
    guard let session = sessions[id] else { throw EngineError.unknownPhoto(id) }
    return session
  }

  /// Opens a photo under an id of the caller's choosing and reports what it is.
  public func open(id: String, url: URL) throws -> PhotoInfo {
    try locked {
      let session = try PhotoSession(url: url)
      sessions[id] = session
      return session.info
    }
  }

  public func close(id: String) {
    locked { sessions[id] = nil }
  }

  /// Opens a file for as long as `work` runs, under an id of its own: for a look at a photo that
  /// is not otherwise open.
  public func with<T>(_ url: URL, _ work: (String, PhotoInfo) throws -> T) throws -> T {
    let id = "temporary-\(UUID().uuidString)"
    let info = try open(id: id, url: url)
    defer { close(id: id) }
    return try work(id, info)
  }

  /// The photo for the screen, in Display P3.
  public func image(id: String, recipe: RenderRecipe, options: RenderOptions) throws -> CGImage {
    try locked {
      let image = try buildImage(session: try session(id), recipe: recipe, options: options)
      guard let rendered = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: tableColorSpace) else {
        throw EngineError.renderFailed("the image could not be drawn")
      }
      return rendered
    }
  }

  /// The photo as an sRGB JPEG: what a model is shown. (Models read sRGB; a wide-gamut file would look washed out to them.)
  public func jpeg(id: String, recipe: RenderRecipe, options: RenderOptions, quality: Double = 0.85) throws -> Data {
    try locked {
      let image = try buildImage(session: try session(id), recipe: recipe, options: options)
      let writeOptions: [CIImageRepresentationOption: Any] = [
        CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): min(1, max(0.1, quality))
      ]
      guard let data = context.jpegRepresentation(of: image, colorSpace: sRGB, options: writeOptions) else {
        throw EngineError.renderFailed("the image could not be encoded")
      }
      return data
    }
  }

  /// A small sRGB RGBA8 bitmap of the photo, top row first, for histograms and statistics.
  public func bitmap(id: String, recipe: RenderRecipe, options: RenderOptions = RenderOptions(maxEdge: 256), longEdge: Int = 192) throws -> (pixels: Data, width: Int, height: Int) {
    try locked {
      let image = try buildImage(session: try session(id), recipe: recipe, options: options)
      return bitmap(of: image, longEdge: longEdge)
    }
  }

  /// A small Display P3 RGBA8 bitmap of the photo, top row first: the values the tone and colour
  /// stages work on, which looks are fitted to.
  public func displayPixels(id: String, recipe: RenderRecipe, longEdge: Int = 384) throws -> PixelBuffer {
    try locked {
      let image = try buildImage(session: try session(id), recipe: recipe, options: RenderOptions(maxEdge: Double(longEdge)))
      let bitmap = bitmap(of: image, longEdge: longEdge, space: tableColorSpace)
      return PixelBuffer(rgba: bitmap.pixels, width: bitmap.width, height: bitmap.height)
    }
  }

  /// The photo with the area a mask covers painted red, as an sRGB JPEG, and the share of the
  /// frame the mask covers (0 to 1).
  public func maskPreview(id: String, recipe: RenderRecipe, mask: Mask, options: RenderOptions, quality: Double = 0.85) throws -> (jpeg: Data, coverage: Double) {
    try locked {
      var options = options
      options.mask = mask
      var coverage = 0.0
      let image = try buildImage(session: try session(id), recipe: recipe, options: options) { shown in
        coverage = self.average(of: shown)
      }
      let writeOptions: [CIImageRepresentationOption: Any] = [
        CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): min(1, max(0.1, quality))
      ]
      guard let data = context.jpegRepresentation(of: image, colorSpace: sRGB, options: writeOptions) else {
        throw EngineError.renderFailed("the image could not be encoded")
      }
      return (data, coverage)
    }
  }

  /// The mean of a grey mask's first channel.
  private func average(of mask: CIImage) -> Double {
    let average = CIFilter.areaAverage()
    average.inputImage = mask
    average.extent = mask.extent
    guard let output = average.outputImage else { return 0 }
    var pixel = [Float](repeating: 0, count: 4)
    context.render(
      output, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: output.extent.minX, y: output.extent.minY, width: 1, height: 1), format: .RGBAf,
      colorSpace: nil)
    return Double(min(1, max(0, pixel[0])))
  }

  /// How many pixels a full-size export develops at a time. A large photo is drawn in bands of
  /// about this many, so no step of its development needs the whole of it in graphics memory at
  /// once (a 48 MP photo with masks and blurs can exceed what a phone allows).
  nonisolated(unsafe) static var exportBandPixels = 8_000_000

  /// Develops the photo at full resolution into a JPEG file, in Display P3, carrying the capture details over.
  public func export(id: String, recipe: RenderRecipe, to url: URL, quality: Double = 0.95) throws -> (width: Int, height: Int) {
    try locked {
      let session = try session(id)
      let image = try buildImage(session: session, recipe: recipe, options: RenderOptions())
      let extent = image.extent
      let width = Int(extent.width.rounded())
      let height = Int(extent.height.rounded())
      guard width > 0, height > 0,
        let canvas = CGContext(
          data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: tableColorSpace,
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
      else { throw EngineError.renderFailed("there is no room for a picture of \(width) × \(height)") }
      canvas.interpolationQuality = .none
      canvas.setBlendMode(.copy)
      // Band by band from the bottom: Core Image and Core Graphics both count up from there, and
      // each band is developed with as much of its surroundings as its blurs and masks reach.
      let rows = max(16, Engine.exportBandPixels / width)
      var row = 0
      while row < height {
        let count = min(rows, height - row)
        let band = CGRect(x: extent.minX, y: extent.minY + CGFloat(row), width: CGFloat(width), height: CGFloat(count))
        guard let part = context.createCGImage(image, from: band, format: .RGBA8, colorSpace: tableColorSpace) else {
          throw EngineError.renderFailed("rows \(row) to \(row + count) of \(height) could not be developed")
        }
        canvas.draw(part, in: CGRect(x: 0, y: row, width: width, height: count))
        row += count
      }
      guard let picture = canvas.makeImage() else { throw EngineError.renderFailed("the developed picture could not be kept") }
      let properties = Engine.exportProperties(session.properties, width: width, height: height, quality: quality)
      guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw EngineError.renderFailed("the JPEG file could not be created")
      }
      CGImageDestinationAddImage(destination, picture, properties as CFDictionary)
      guard CGImageDestinationFinalize(destination) else { throw EngineError.renderFailed("the JPEG could not be written") }
      return (width, height)
    }
  }

  /// The capture details of the file a photo was opened from, for a JPEG of it: what describes the
  /// original's own pixels (a RAW's sensor layout, its size, bit depth and turn) is left out or
  /// made true of the JPEG.
  static func exportProperties(_ source: [String: Any], width: Int, height: Int, quality: Double) -> [String: Any] {
    var properties = source
    for key in [
      kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth, kCGImagePropertyColorModel, kCGImagePropertyProfileName,
      kCGImagePropertyHasAlpha, kCGImagePropertyIsFloat, kCGImagePropertyIsIndexed, kCGImagePropertyDNGDictionary, kCGImagePropertyRawDictionary,
    ] {
      properties[key as String] = nil
    }
    // The turn is already in the pixels.
    properties[kCGImagePropertyOrientation as String] = 1
    if var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
      tiff[kCGImagePropertyTIFFOrientation as String] = 1
      tiff[kCGImagePropertyTIFFCompression as String] = nil
      tiff[kCGImagePropertyTIFFPhotometricInterpretation as String] = nil
      properties[kCGImagePropertyTIFFDictionary as String] = tiff
    }
    if var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
      exif[kCGImagePropertyExifPixelXDimension as String] = width
      exif[kCGImagePropertyExifPixelYDimension as String] = height
      properties[kCGImagePropertyExifDictionary as String] = exif
    }
    properties[kCGImageDestinationLossyCompressionQuality as String] = min(1, max(0.1, quality))
    return properties
  }

  /// The fully processed image, with its extent starting at the origin. With `options.mask`, the
  /// mask is painted over it and handed to `shownMask` too.
  func buildImage(session: PhotoSession, recipe: RenderRecipe, options: RenderOptions, shownMask: ((CIImage) -> Void)? = nil) throws -> CIImage {
    session.use(recipe.layout)
    // Size of the output at full resolution, to choose how much to scale down before processing.
    let quarterTurned = abs(recipe.rotation) % 180 == 90
    var frame = quarterTurned ? CGSize(width: session.size.height, height: session.size.width) : session.size
    let trim = Engine.straightenScale(angle: recipe.angle, size: frame)
    frame = CGSize(width: frame.width * trim, height: frame.height * trim)
    if !options.fullFrame {
      frame = CGSize(width: frame.width * recipe.cropWidth, height: frame.height * recipe.cropHeight)
    }
    if let region = options.region {
      frame = CGSize(width: frame.width * region.width, height: frame.height * region.height)
    }
    let longEdge = max(frame.width, frame.height)
    let scale = options.maxEdge > 0 ? min(1, CGFloat(options.maxEdge) / longEdge) : 1
    // Ordinary previews share one developed image; exports and zooms develop at their own size.
    let cache = options.maxEdge > 0 && options.maxEdge <= Engine.previewEdge && options.region == nil

    var image = try session.developed(recipe: recipe, scale: scale, cache: cache, context: context)
    let developedImage = image
    let extent = image.extent
    let workingEdge = max(extent.width, extent.height)

    if recipe.shadowAmount > 0 || recipe.highlightAmount < 1 {
      let filter = CIFilter.highlightShadowAdjust()
      filter.inputImage = image.clampedToExtent()
      filter.shadowAmount = Float(recipe.shadowAmount)
      filter.highlightAmount = Float(recipe.highlightAmount)
      image = (filter.outputImage ?? image).cropped(to: extent)
    }

    for pass in recipe.localContrast where pass.intensity != 0 {
      let filter = CIFilter.unsharpMask()
      filter.inputImage = image.clampedToExtent()
      filter.radius = Float(pass.radius * Double(workingEdge))
      filter.intensity = Float(pass.intensity)
      image = (filter.outputImage ?? image).cropped(to: extent)
    }

    if recipe.toneTableSize >= 2, recipe.toneTable.count == recipe.toneTableSize * 3 * MemoryLayout<Float32>.size {
      let filter = CIFilter.colorCurves()
      filter.inputImage = image
      filter.curvesData = recipe.toneTable
      filter.curvesDomain = CIVector(x: 0, y: 1)
      filter.colorSpace = tableColorSpace
      image = filter.outputImage ?? image
    }

    let cubeEntries = recipe.cubeSize * recipe.cubeSize * recipe.cubeSize
    if recipe.cubeSize >= 2, recipe.cube.count == cubeEntries * 4 * MemoryLayout<Float32>.size {
      let filter = CIFilter.colorCubeWithColorSpace()
      filter.inputImage = image
      filter.cubeDimension = Float(recipe.cubeSize)
      filter.cubeData = recipe.cube
      filter.colorSpace = tableColorSpace
      image = filter.outputImage ?? image
    }

    if let halation = recipe.halation {
      image = Effects.halation(image, halation, edge: workingEdge)
    }

    image = geometry(image, recipe: recipe, fullFrame: options.fullFrame)

    // How far each part of the frame is: a band's weight, or without one the distance itself.
    let depth: (ValueRange?) -> CIImage? = { band in
      guard let estimator = self.depthEstimator, let map = session.depth(estimator: estimator, context: self.context) else { return nil }
      return self.geometry(Effects.depthImage(map, band: band, extent: extent), recipe: recipe, fullFrame: options.fullFrame)
    }
    if options.depth {
      guard let distances = depth(nil) else { throw EngineError.renderFailed("this build cannot estimate depth") }
      // Decoded, so that once encoded for display each grey is the distance itself.
      let decode = CIFilter.sRGBToneCurveToLinear()
      decode.inputImage = distances
      return Engine.region(of: decode.outputImage ?? distances, options.region)
    }

    var maskToShow: CIImage?
    if !recipe.local.isEmpty || options.mask != nil {
      let frameExtent = image.extent
      // The subject and people masks follow the photo through the same flips, turns and crop.
      var framed: [String: CIImage] = [:]
      let geometryKey = [
        recipe.flipHorizontal, recipe.flipVertical, options.fullFrame,
      ].map { $0 ? "1" : "0" }.joined()
        + "|\(recipe.rotation)|\(recipe.angle)|\(recipe.cropX)|\(recipe.cropY)|\(recipe.cropWidth)|\(recipe.cropHeight)"
      let found: (MaskArea) -> CIImage? = { area in
        if area.type == "object" {
          guard let segmenter = self.segmenter else { return nil }
          let logits = session.selection(
            points: area.points, exclude: area.exclude, framing: geometryKey, segmenter: segmenter,
            picture: { self.selectionPicture(session: session, recipe: recipe, fullFrame: options.fullFrame) })
          return logits.map { Effects.objectMask($0, frame: frameExtent) }
        }
        let kind = area.type
        if let mask = framed[kind] { return mask }
        guard let mask = session.foundMask(kind, extent: extent, context: self.context) else { return nil }
        let placed = self.geometry(mask, recipe: recipe, fullFrame: options.fullFrame)
        framed[kind] = placed
        return placed
      }
      // The photo as developed, before tone and colour, for ranges measured there.
      var originalFrame: CIImage?
      let original: () -> CIImage = {
        if let originalFrame { return originalFrame }
        let placed = self.geometry(developedImage, recipe: recipe, fullFrame: options.fullFrame)
        originalFrame = placed
        return placed
      }
      let frameEdge = max(image.extent.width, image.extent.height)
      for pass in recipe.local {
        let mask = Effects.mask(pass.mask, over: image, original: original, found: found, depth: { depth($0) }, context: self.context)
        image = Effects.local(pass, to: image, mask: mask, edge: frameEdge)
      }
      if let shown = options.mask {
        maskToShow = Effects.mask(shown, over: image, original: original, found: found, depth: { depth($0) }, context: self.context)
      }
    }

    if recipe.vignette != 0, !options.fullFrame {
      image = vignette(image, amount: recipe.vignette)
    }
    if let grain = recipe.grain {
      image = Effects.grain(image, grain)
    }
    if let mask = maskToShow {
      image = Effects.overlay(image, mask: mask)
      shownMask?(mask)
    }
    return Engine.region(of: image, options.region)
  }

  /// Part of the frame, as fractions from its top-left corner, with its extent at the origin.
  private static func region(of image: CIImage, _ region: CGRect?) -> CIImage {
    guard let region else { return image }
    let size = image.extent.size
    // Regions are measured from the top; Core Image from the bottom.
    let rect = CGRect(
      x: (size.width * region.minX).rounded(), y: (size.height * (1 - region.minY - region.height)).rounded(),
      width: max(1, (size.width * region.width).rounded()), height: max(1, (size.height * region.height).rounded())
    ).intersection(image.extent)
    return image.cropped(to: rect).atOrigin()
  }

  /// What the segmentation model looks at: the photo as opened, small, framed as it is now.
  private func selectionPicture(session: PhotoSession, recipe: RenderRecipe, fullFrame: Bool) -> CGImage? {
    guard let picture = session.analysisImage(context: context) else { return nil }
    let framed = geometry(CIImage(cgImage: picture), recipe: recipe, fullFrame: fullFrame)
    return context.createCGImage(framed, from: framed.extent, format: .RGBA8, colorSpace: sRGB)
  }

  /// Flips, quarter turns, straightening and the crop rectangle. All sizes are relative, so the
  /// result is the same at any resolution.
  private func geometry(_ input: CIImage, recipe: RenderRecipe, fullFrame: Bool) -> CIImage {
    var image = input
    if recipe.flipHorizontal {
      image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1)).atOrigin()
    }
    if recipe.flipVertical {
      image = image.transformed(by: CGAffineTransform(scaleX: 1, y: -1)).atOrigin()
    }
    let turns = ((recipe.rotation / 90) % 4 + 4) % 4
    if turns != 0 {
      // Core Image's y axis points up, so a negative angle turns clockwise on screen.
      image = image.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(turns) * .pi / 2)).atOrigin()
    }
    if abs(recipe.angle) > 0.001 {
      let size = image.extent.size
      let trim = Engine.straightenScale(angle: recipe.angle, size: size)
      let rotated = image.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(recipe.angle) * .pi / 180))
      let centre = CGPoint(x: rotated.extent.midX, y: rotated.extent.midY)
      let kept = CGSize(width: (size.width * trim).rounded(.down), height: (size.height * trim).rounded(.down))
      let rect = CGRect(x: centre.x - kept.width / 2, y: centre.y - kept.height / 2, width: kept.width, height: kept.height)
      image = rotated.cropped(to: rect).atOrigin()
    }
    if !fullFrame, recipe.cropX > 0 || recipe.cropY > 0 || recipe.cropWidth < 1 || recipe.cropHeight < 1 {
      let size = image.extent.size
      let width = max(1, (size.width * CGFloat(recipe.cropWidth)).rounded())
      let height = max(1, (size.height * CGFloat(recipe.cropHeight)).rounded())
      let x = (size.width * CGFloat(recipe.cropX)).rounded()
      // The recipe measures y from the top; Core Image from the bottom.
      let y = (size.height * CGFloat(1 - recipe.cropY - recipe.cropHeight)).rounded()
      let rect = CGRect(x: x, y: y, width: width, height: height).intersection(image.extent)
      image = image.cropped(to: rect).atOrigin()
    }
    let extent = image.extent
    let integral = CGRect(x: 0, y: 0, width: extent.width.rounded(.down), height: extent.height.rounded(.down))
    return image.cropped(to: integral)
  }

  /// Darkens (amount > 0) or lightens (amount < 0) towards the corners by up to 1.6 stops.
  private func vignette(_ image: CIImage, amount: Double) -> CIImage {
    let extent = image.extent
    let adjusted = CIFilter.exposureAdjust()
    adjusted.inputImage = image
    adjusted.ev = Float(-1.6 * amount)

    // A circular mask in a unit square, stretched to the frame: black in the middle, white at the corners.
    let unit: CGFloat = 1000
    let gradient = CIFilter.radialGradient()
    gradient.center = CGPoint(x: unit / 2, y: unit / 2)
    gradient.radius0 = Float(unit * 0.3)
    gradient.radius1 = Float(unit * 0.75)
    gradient.color0 = CIColor(red: 0, green: 0, blue: 0)
    gradient.color1 = CIColor(red: 1, green: 1, blue: 1)
    guard let mask = gradient.outputImage, let edges = adjusted.outputImage else { return image }
    let stretched = mask.transformed(by: CGAffineTransform(scaleX: extent.width / unit, y: extent.height / unit))

    let blend = CIFilter.blendWithMask()
    blend.inputImage = edges
    blend.backgroundImage = image
    blend.maskImage = stretched.cropped(to: extent)
    return (blend.outputImage ?? image).cropped(to: extent)
  }

  /// A small RGBA8 copy of the image, top row first, in sRGB unless another space is given.
  func bitmap(of image: CIImage, longEdge: Int, space: CGColorSpace? = nil) -> (pixels: Data, width: Int, height: Int) {
    let extent = image.extent
    let factor = min(1, CGFloat(longEdge) / max(extent.width, extent.height))
    var small = image
    if factor < 1 {
      let resize = CIFilter.lanczosScaleTransform()
      resize.inputImage = image
      resize.scale = Float(factor)
      resize.aspectRatio = 1
      small = (resize.outputImage ?? image).atOrigin()
    }
    let width = max(1, Int(small.extent.width.rounded(.down)))
    let height = max(1, Int(small.extent.height.rounded(.down)))
    var data = Data(count: width * height * 4)
    data.withUnsafeMutableBytes { buffer in
      if let base = buffer.baseAddress {
        context.render(
          small, toBitmap: base, rowBytes: width * 4, bounds: CGRect(x: 0, y: 0, width: width, height: height),
          format: .RGBA8, colorSpace: space ?? sRGB)
      }
    }
    return (data, width, height)
  }

  /// The fraction of a frame that survives straightening: the largest rectangle with the same
  /// proportions that fits inside the turned frame. Mirrors `straightenScale` in src/engine/state.ts.
  static func straightenScale(angle: Double, size: CGSize) -> CGFloat {
    guard abs(angle) > 0.001, size.width > 0, size.height > 0 else { return 1 }
    let radians = CGFloat(abs(angle)) * .pi / 180
    let long = max(size.width / size.height, size.height / size.width)
    return 1 / (cos(radians) + long * sin(radians))
  }
}
