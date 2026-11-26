import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import OscuruCore
import UniformTypeIdentifiers

/// Opens photos and renders recipes with Core Image. Safe to call from any thread: each photo
/// renders one thing at a time, and different photos render at the same time, so one photo's long
/// render does not hold up the others. Full-size work (exports, zooms) runs one at a time across
/// all photos, so two of them never need their memory at once.
///
/// Pipeline, in order: develop (exposure, white balance, noise reduction, in linear light; for RAW
/// files, Apple's decoder with its looks off, then Oscuru's base curve) → local highlight and shadow recovery → local contrast → tone tables → colour cube →
/// halation → flips, rotation, straightening, crop → local adjustments → vignette → grain → output.
public final class Engine: @unchecked Sendable {
  /// Draws on the graphics processor.
  private let gpu: CIContext
  /// Draws on the processor: for while the app is in the background, where iOS does not let it use
  /// the graphics processor (Core Image's drawing there fails).
  private let cpu: CIContext

  /// Guards `sessions` and `background`; never held while anything renders.
  private let lock = NSLock()
  private var sessions: [String: PhotoSession] = [:]
  private var background = false
  /// Held by full-size work, one at a time (see `using`).
  private let large = NSLock()

  /// Tables are defined in gamma-encoded Display P3.
  private let tableColorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
  private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

  /// Renders up to this long edge share one developed image per photo.
  static let previewEdge: Double = 2048

  /// Where the on-device models are (see `Segmenter`, `DepthEstimator`); nil when this build has none.
  private let models: URL?
  /// Guards loading the models.
  private let modelLock = NSLock()
  private var loadedSegmenter: Segmenter?
  private var loadedDepthEstimator: DepthEstimator?
  /// When loading each last failed: tried again a little later, not on every render, and not never.
  private var segmenterFailed: Date?
  private var depthEstimatorFailed: Date?

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
    var software = options
    software[.useSoftwareRenderer] = true
    gpu = CIContext(options: useSoftwareRenderer ? software : options)
    cpu = CIContext(options: software)
  }

  /// The context renders draw with now.
  public var context: CIContext { isInBackground ? cpu : gpu }

  /// Set while the app is in the background: renders then draw on the processor, slower but drawn.
  public var isInBackground: Bool {
    get { lock.withLock { background } }
    set { lock.withLock { background = newValue } }
  }

  /// Runs `work` on an open photo, holding it: a photo renders one thing at a time, while other
  /// photos render. `large` work (`isLarge`) also waits for other large work, and lets go of what
  /// it left in Core Image's cache when done.
  private func using<T>(_ id: String, large isLarge: Bool = false, _ work: (PhotoSession) throws -> T) throws -> T {
    let session = try lock.withLock { () throws -> PhotoSession in
      guard let session = sessions[id] else { throw EngineError.unknownPhoto(id) }
      return session
    }
    session.lock.lock()
    defer { session.lock.unlock() }
    guard isLarge else { return try work(session) }
    large.lock()
    defer {
      gpu.clearCaches()
      cpu.clearCaches()
      large.unlock()
    }
    return try work(session)
  }

  /// A render that develops more than a preview's worth: at full size, larger than a preview, or a
  /// part of the frame (developed at whatever size the part needs).
  static func isLarge(_ options: RenderOptions) -> Bool {
    options.maxEdge <= 0 || options.maxEdge > previewEdge || options.region != nil
  }

  private var segmenter: Segmenter? {
    modelLock.withLock {
      if loadedSegmenter == nil, let models, Engine.mayRetry(segmenterFailed) {
        loadedSegmenter = try? Segmenter(folder: models)
        segmenterFailed = loadedSegmenter == nil ? Date() : nil
      }
      return loadedSegmenter
    }
  }

  private var depthEstimator: DepthEstimator? {
    modelLock.withLock {
      if loadedDepthEstimator == nil, let models, Engine.mayRetry(depthEstimatorFailed) {
        loadedDepthEstimator = try? DepthEstimator(folder: models)
        depthEstimatorFailed = loadedDepthEstimator == nil ? Date() : nil
      }
      return loadedDepthEstimator
    }
  }

  private static func mayRetry(_ failed: Date?) -> Bool {
    guard let failed else { return true }
    return Date().timeIntervalSince(failed) > 30
  }

  /// Opens a photo under an id of the caller's choosing and reports what it is.
  public func open(id: String, url: URL) throws -> PhotoInfo {
    let session = try PhotoSession(url: url)
    lock.withLock { sessions[id] = session }
    return session.info
  }

  /// Closes a photo. A render of it already under way finishes first.
  public func close(id: String) {
    lock.withLock { sessions[id] = nil }
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
    try using(id, large: Engine.isLarge(options)) { session in
      let image = try buildImage(session: session, recipe: recipe, options: options)
      return try context.picture(of: image, space: tableColorSpace)
    }
  }

  /// The photo as an sRGB JPEG: what a model is shown. (Models read sRGB; a wide-gamut file would look washed out to them.)
  public func jpeg(id: String, recipe: RenderRecipe, options: RenderOptions, quality: Double = 0.85) throws -> Data {
    try using(id, large: Engine.isLarge(options)) { session in
      let image = try buildImage(session: session, recipe: recipe, options: options)
      return try JPEG.data(of: try context.picture(of: image, space: sRGB), quality: quality)
    }
  }

  /// A small sRGB RGBA8 bitmap of the photo, top row first, for histograms and statistics.
  public func bitmap(id: String, recipe: RenderRecipe, options: RenderOptions = RenderOptions(maxEdge: 256), longEdge: Int = 192) throws -> (pixels: Data, width: Int, height: Int) {
    try using(id, large: Engine.isLarge(options)) { session in
      let image = try buildImage(session: session, recipe: recipe, options: options)
      return try bitmap(of: image, longEdge: longEdge)
    }
  }

  /// A small Display P3 RGBA8 bitmap of the photo, top row first: the values the tone and colour
  /// stages work on, which looks are fitted to.
  public func displayPixels(id: String, recipe: RenderRecipe, longEdge: Int = 384) throws -> PixelBuffer {
    try using(id) { session in
      let image = try buildImage(session: session, recipe: recipe, options: RenderOptions(maxEdge: Double(longEdge)))
      let bitmap = try bitmap(of: image, longEdge: longEdge, space: tableColorSpace)
      return PixelBuffer(rgba: bitmap.pixels, width: bitmap.width, height: bitmap.height)
    }
  }

  /// The photo with the area a mask covers painted red, as an sRGB JPEG, and the share of the
  /// frame the mask covers (0 to 1).
  public func maskPreview(id: String, recipe: RenderRecipe, mask: Mask, options: RenderOptions, quality: Double = 0.85) throws -> (jpeg: Data, coverage: Double) {
    try using(id, large: Engine.isLarge(options)) { session in
      var options = options
      options.mask = mask
      var coverage = 0.0
      let image = try buildImage(session: session, recipe: recipe, options: options) { shown in
        coverage = self.average(of: shown)
      }
      return (try JPEG.data(of: try context.picture(of: image, space: sRGB), quality: quality), coverage)
    }
  }

  /// What lining up and merging a shot's frames the way `recipe` says found of each frame, by its
  /// number, making the merge now if it is not kept already. Nil when the photo has no frames, or
  /// they cannot be merged that way.
  public func frameReports(id: String, recipe: RenderRecipe) throws -> [Int: FrameReport]? {
    try using(id) { session in session.frameReports(for: recipe.frames?.way) }
  }

  /// The mean of a grey mask's first channel (0 when it could not be measured).
  private func average(of mask: CIImage) -> Double {
    let average = CIFilter.areaAverage()
    average.inputImage = mask
    average.extent = mask.extent
    guard let output = average.outputImage else { return 0 }
    var pixel = [Float](repeating: 0, count: 4)
    let drawn: ()? = pixel.withUnsafeMutableBytes { buffer in
      buffer.baseAddress.flatMap { base in
        try? context.draw(
          output, into: base, rowBytes: 16, bounds: CGRect(x: output.extent.minX, y: output.extent.minY, width: 1, height: 1), format: .RGBAf,
          colorSpace: nil)
      }
    }
    guard drawn != nil else { return 0 }
    return Double(min(1, max(0, pixel[0])))
  }

  /// How many pixels a full-size export develops at a time. A large photo is drawn in bands of
  /// about this many, so no step of its development needs the whole of it in graphics memory at
  /// once (a 48 MP photo with masks and blurs can exceed what a phone allows).
  nonisolated(unsafe) static var exportBandPixels = 8_000_000

  /// Develops the photo at full resolution into a JPEG file, in Display P3, carrying the capture details over.
  public func export(id: String, recipe: RenderRecipe, to url: URL, quality: Double = 0.95) throws -> (width: Int, height: Int) {
    try using(id, large: true) { session in
      let image = try buildImage(session: session, recipe: recipe, options: RenderOptions())
      let extent = image.extent
      let width = Int(extent.width.rounded())
      let height = Int(extent.height.rounded())
      guard width > 0, height > 0,
        let canvas = CGContext(
          data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: tableColorSpace,
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
        let memory = canvas.data
      else { throw EngineError.renderFailed("there is no room for a picture of \(width) × \(height)") }
      let rowBytes = canvas.bytesPerRow
      // Band by band from the bottom, as Core Image counts, each drawn straight into its rows of
      // the picture (which are kept top row first) with as much of its surroundings as its blurs
      // and masks reach.
      let rows = max(16, Engine.exportBandPixels / width)
      var row = 0
      while row < height {
        let count = min(rows, height - row)
        let band = CGRect(x: extent.minX, y: extent.minY + CGFloat(row), width: CGFloat(width), height: CGFloat(count))
        let start = memory.advanced(by: (height - row - count) * rowBytes)
        start.initializeMemory(as: UInt8.self, repeating: 0, count: count * rowBytes)
        do {
          try context.draw(image, into: start, rowBytes: rowBytes, bounds: band, format: .RGBA8, colorSpace: tableColorSpace)
        } catch {
          throw EngineError.renderFailed("rows \(row) to \(row + count) of \(height) could not be developed")
        }
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

    let developedImage = try session.developed(recipe: recipe, scale: scale, cache: cache, context: context)
    let extent = developedImage.extent
    let workingEdge = max(extent.width, extent.height)

    /// Everything that is done to the whole of a developed picture, up to and with its framing.
    func finished(_ developed: CIImage) -> CIImage {
      var image = developed

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

      return geometry(image, recipe: recipe, fullFrame: options.fullFrame)
    }
    var image = finished(developedImage)

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
    let areas = recipe.frames?.areas ?? []
    if !recipe.local.isEmpty || options.mask != nil || !areas.isEmpty {
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
      // A mask that snaps to the photo's edges needs the whole frame as pixels. On a large render
      // (a zoom, an export) it is worked out on a small development instead: see `smallMask`.
      let mask: (Mask, MaskPlace, CIImage) throws -> CIImage = { mask, before, current in
        if mask.refine > 0, frameEdge > Engine.previewEdge {
          return try self.smallMask(mask, before: before, session: session, recipe: recipe, fullFrame: options.fullFrame, frame: current.extent)
        }
        return Effects.mask(mask, over: current, original: original, found: found, depth: { depth($0) }, context: self.context)
      }
      // Parts of the picture from the shot's frames merged another way, each developed like the
      // rest and laid in through its mask.
      for (index, area) in areas.enumerated() {
        let other = finished(try session.developed(recipe: recipe, way: area.way, scale: scale, cache: cache, context: context))
        image = Effects.blend(other, over: image, mask: try mask(area.mask, MaskPlace(areas: index, local: 0), image))
      }
      for (index, pass) in recipe.local.enumerated() {
        image = Effects.local(pass, to: image, mask: try mask(pass.mask, MaskPlace(areas: areas.count, local: index), image), edge: frameEdge)
      }
      if let shown = options.mask {
        maskToShow = try mask(shown, MaskPlace(areas: areas.count, local: recipe.local.count), image)
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

  /// The long edge of the small development a large render's edge-snapping masks are worked out
  /// on. Snapping works on at most 1024 pixels in any case (`Effects.refined`).
  static let maskEdge: Double = 1024

  /// Where in the order of things done through masks one stands: after this many of the frames'
  /// areas and this many local adjustments.
  struct MaskPlace {
    var areas: Int
    var local: Int
  }

  /// A mask as it would be over the photo at the place `before`, worked out on a small
  /// development of the photo and stretched over `frame`. Snapping a mask to the photo's edges reads
  /// the whole frame back as pixels; on a full-size picture that develops all of it at full size
  /// (for a zoom of one corner, or one band of an export, as much as for the whole), which can need
  /// more graphics memory than a phone has. The snapped mask is only ever 1024 pixels across, so
  /// working it out small gives the same mask.
  private func smallMask(_ mask: Mask, before: MaskPlace, session: PhotoSession, recipe: RenderRecipe, fullFrame: Bool, frame: CGRect) throws -> CIImage {
    var earlier = recipe
    earlier.local = Array(recipe.local.prefix(before.local))
    earlier.frames?.areas = Array((recipe.frames?.areas ?? []).prefix(before.areas))
    earlier.vignette = 0
    earlier.grain = nil
    var found: CIImage?
    _ = try buildImage(session: session, recipe: earlier, options: RenderOptions(maxEdge: Engine.maskEdge, fullFrame: fullFrame, mask: mask)) { found = $0 }
    let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: frame)
    guard let small = found, !small.extent.isEmpty, !small.extent.isInfinite, !frame.isEmpty, !frame.isInfinite else { return black }
    // Kept as pixels, so the large render does not develop the small one again.
    let picture = try context.picture(of: small.atOrigin(), space: nil)
    let width = picture.width
    let height = picture.height
    return Effects.opaque(
      CIImage(cgImage: picture, options: [.colorSpace: NSNull()])
        .clampedToExtent()
        .samplingLinear()
        .transformed(by: CGAffineTransform(scaleX: frame.width / CGFloat(width), y: frame.height / CGFloat(height)))
        .transformed(by: CGAffineTransform(translationX: frame.minX, y: frame.minY))
    ).cropped(to: frame)
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
    return try? context.picture(of: framed, space: sRGB)
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
  func bitmap(of image: CIImage, longEdge: Int, space: CGColorSpace? = nil) throws -> (pixels: Data, width: Int, height: Int) {
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
    try data.withUnsafeMutableBytes { buffer in
      guard let base = buffer.baseAddress else { throw EngineError.renderFailed("there is no room for the picture") }
      try context.draw(
        small, into: base, rowBytes: width * 4, bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: space ?? sRGB)
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
