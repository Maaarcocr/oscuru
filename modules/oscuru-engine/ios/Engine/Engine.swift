import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO

/// Opens photos and renders recipes. Use from one queue at a time.
///
/// Pipeline, in order: develop (exposure, white balance, noise reduction, in linear light) →
/// local highlight and shadow recovery → local contrast → tone tables → colour cube →
/// flips, rotation, straightening, crop → vignette → output.
public final class Engine {
  public let context: CIContext
  private let outputDirectory: URL
  private var sessions: [String: PhotoSession] = [:]
  private var slotFiles: [String: URL] = [:]
  private var counter = 0

  /// Tables are defined in gamma-encoded Display P3.
  private let tableColorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
  private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

  /// Previews up to this long edge reuse the developed image between renders.
  private static let cachedPreviewEdge: Double = 2600

  public init(outputDirectory: URL, useSoftwareRenderer: Bool = false) {
    self.outputDirectory = outputDirectory
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

  public func open(id: String, url: URL) throws -> [String: Any] {
    let session = try PhotoSession(url: url)
    sessions[id] = session
    return session.metadata
  }

  public func close(id: String) {
    sessions[id] = nil
    for key in slotFiles.keys where key.hasPrefix(id + "/") {
      if let url = slotFiles[key] {
        try? FileManager.default.removeItem(at: url)
      }
      slotFiles[key] = nil
    }
  }

  public func render(id: String, recipe: RenderRecipe, options: RenderOptions) throws -> RenderResult {
    guard let session = sessions[id] else {
      throw EngineError.unknownSession(id)
    }
    let image = try buildImage(session: session, recipe: recipe, options: options)
    let width = Int(image.extent.width.rounded(.down))
    let height = Int(image.extent.height.rounded(.down))
    guard width > 0, height > 0 else {
      throw EngineError.renderFailed("the crop leaves no pixels")
    }

    let directory = outputDirectory.appendingPathComponent(id, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    counter += 1
    let isHEIC = options.format == "heic"
    let url = directory.appendingPathComponent("\(options.slot)-\(counter).\(isHEIC ? "heic" : "jpg")")
    let colorSpace = options.colorSpace == "srgb" ? sRGB : tableColorSpace
    let quality = min(1, max(0.1, options.quality))
    let writeOptions: [CIImageRepresentationOption: Any] = [
      CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality
    ]
    var output = image
    if options.maxEdge == 0 {
      // Exports keep the capture details; the orientation is already applied to the pixels.
      var properties = session.properties
      properties[kCGImagePropertyOrientation as String] = 1
      properties[kCGImagePropertyPixelWidth as String] = nil
      properties[kCGImagePropertyPixelHeight as String] = nil
      if var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
        tiff[kCGImagePropertyTIFFOrientation as String] = 1
        properties[kCGImagePropertyTIFFDictionary as String] = tiff
      }
      output = image.settingProperties(properties)
    }
    do {
      if isHEIC {
        try context.writeHEIFRepresentation(of: output, to: url, format: .RGBA8, colorSpace: colorSpace, options: writeOptions)
      } else {
        try context.writeJPEGRepresentation(of: output, to: url, colorSpace: colorSpace, options: writeOptions)
      }
    } catch {
      throw EngineError.renderFailed(error.localizedDescription)
    }

    let slotKey = "\(id)/\(options.slot)"
    if let previous = slotFiles[slotKey] {
      try? FileManager.default.removeItem(at: previous)
    }
    slotFiles[slotKey] = url

    var result = RenderResult(url: url, width: width, height: height)
    if options.statsEdge > 0 {
      let (pixels, statsWidth, statsHeight) = bitmap(of: image, longEdge: options.statsEdge)
      result.statsPixels = pixels
      result.statsWidth = statsWidth
      result.statsHeight = statsHeight
    }
    return result
  }

  /// The fully processed image, with its extent starting at the origin.
  func buildImage(session: PhotoSession, recipe: RenderRecipe, options: RenderOptions) throws -> CIImage {
    // Size of the output at full resolution, to choose how much to scale down before processing.
    let quarterTurned = abs(recipe.rotation) % 180 == 90
    var frame = quarterTurned ? CGSize(width: session.size.height, height: session.size.width) : session.size
    let trim = Engine.straightenScale(angle: recipe.angle, size: frame)
    frame = CGSize(width: frame.width * trim, height: frame.height * trim)
    if !options.fullFrame {
      frame = CGSize(width: frame.width * recipe.cropWidth, height: frame.height * recipe.cropHeight)
    }
    let longEdge = max(frame.width, frame.height)
    let scale = options.maxEdge > 0 ? min(1, CGFloat(options.maxEdge) / longEdge) : 1
    let cache = options.maxEdge > 0 && options.maxEdge <= Engine.cachedPreviewEdge

    var image = try session.developed(recipe: recipe, scale: scale, cache: cache, context: context)
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

    image = geometry(image, recipe: recipe, fullFrame: options.fullFrame)

    if recipe.vignette != 0, !options.fullFrame {
      image = vignette(image, amount: recipe.vignette)
    }
    return image
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

  /// A small sRGB RGBA8 copy of the image, top row first.
  func bitmap(of image: CIImage, longEdge: Int) -> (Data, Int, Int) {
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
          format: .RGBA8, colorSpace: sRGB)
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
