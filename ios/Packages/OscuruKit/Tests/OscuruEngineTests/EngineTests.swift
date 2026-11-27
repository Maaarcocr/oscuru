import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

import OscuruCore

@testable import OscuruEngine

/// These tests pin down what the TypeScript side assumes about Core Image: table layouts, colour
/// spaces, directions of rotation and white balance, and that a RAW file goes through the RAW decoder.
final class EngineTests: XCTestCase {
  private var directory: URL!
  private var engine: Engine!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("oscuru-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    engine = Engine(useSoftwareRenderer: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  // MARK: Helpers

  typealias RGB = (r: Double, g: Double, b: Double)

  /// Writes an sRGB PNG whose pixels come from `paint(x, y)`, with y counted from the top.
  private func makePNG(_ name: String, width: Int, height: Int, paint: (Int, Int) -> RGB) throws -> URL {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let colour = paint(x, y)
        let offset = (y * width + x) * 4
        bytes[offset] = UInt8(max(0, min(255, (colour.r * 255).rounded())))
        bytes[offset + 1] = UInt8(max(0, min(255, (colour.g * 255).rounded())))
        bytes[offset + 2] = UInt8(max(0, min(255, (colour.b * 255).rounded())))
      }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let image = CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let url = directory.appendingPathComponent(name)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return url
  }

  private func grey(_ value: Double) -> (Int, Int) -> RGB {
    { _, _ in (value, value, value) }
  }

  private struct Pixels {
    let data: Data
    let width: Int
    let height: Int

    func at(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
      let offset = (y * width + x) * 4
      return (Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2]), Int(data[offset + 3]))
    }

    var mean: (r: Double, g: Double, b: Double) {
      var sums = (0.0, 0.0, 0.0)
      for index in 0..<(width * height) {
        sums.0 += Double(data[index * 4])
        sums.1 += Double(data[index * 4 + 1])
        sums.2 += Double(data[index * 4 + 2])
      }
      let count = Double(width * height)
      return (sums.0 / count, sums.1 / count, sums.2 / count)
    }
  }

  private struct Size: Equatable {
    let width: Int
    let height: Int
  }

  /// Renders through the same paths the app uses and returns the picture's size and its pixels.
  private func render(_ id: String, _ recipe: RenderRecipe = RenderRecipe(), maxEdge: Double = 512, fullFrame: Bool = false, region: CGRect? = nil) throws -> (Size, Pixels) {
    let options = RenderOptions(maxEdge: maxEdge, fullFrame: fullFrame, region: region)
    let image = try engine.image(id: id, recipe: recipe, options: options)
    let bitmap = try engine.bitmap(id: id, recipe: recipe, options: options, longEdge: 512)
    return (Size(width: image.width, height: image.height), Pixels(data: bitmap.pixels, width: bitmap.width, height: bitmap.height))
  }

  private func floats(_ values: [Float]) -> Data {
    values.withUnsafeBufferPointer { Data(buffer: $0) }
  }

  // MARK: Opening

  func testOpenReportsSizeAndDefaults() throws {
    let url = try makePNG("plain.png", width: 60, height: 40, paint: grey(0.5))
    let info = try engine.open(id: "a", url: url)
    XCTAssertEqual(info.width, 60)
    XCTAssertEqual(info.height, 40)
    XCTAssertFalse(info.isRaw)
    XCTAssertEqual(info.fileName, "plain.png")
    XCTAssertEqual(info.defaults, PhotoDefaults())
  }

  func testOpeningSomethingThatIsNotAnImageFails() throws {
    let url = directory.appendingPathComponent("notes.txt")
    try Data("hello".utf8).write(to: url)
    XCTAssertThrowsError(try engine.open(id: "a", url: url))
  }

  func testRenderingAnUnknownSessionFails() {
    XCTAssertThrowsError(try engine.image(id: "nope", recipe: RenderRecipe(), options: RenderOptions()))
    XCTAssertThrowsError(try engine.jpeg(id: "nope", recipe: RenderRecipe(), options: RenderOptions()))
  }

  // MARK: Output

  func testIdentityRecipeKeepsThePhoto() throws {
    let url = try makePNG("ramp.png", width: 64, height: 32) { x, _ in
      let value = Double(x) / 63
      return (value, value * 0.5, 1 - value)
    }
    _ = try engine.open(id: "a", url: url)
    let (result, pixels) = try render("a")
    XCTAssertEqual(result, Size(width: 64, height: 32))
    for x in [0, 20, 40, 63] {
      let expected = Double(x) / 63
      let pixel = pixels.at(x, 10)
      XCTAssertEqual(Double(pixel.r), expected * 255, accuracy: 3)
      XCTAssertEqual(Double(pixel.g), expected * 0.5 * 255, accuracy: 3)
      XCTAssertEqual(Double(pixel.b), (1 - expected) * 255, accuracy: 3)
      XCTAssertEqual(pixel.a, 255)
    }
  }

  func testBitmapIsTopRowFirst() throws {
    let url = try makePNG("halves.png", width: 20, height: 20) { _, y in y < 10 ? (1, 0, 0) : (0, 0, 1) }
    _ = try engine.open(id: "a", url: url)
    let (_, pixels) = try render("a")
    XCTAssertGreaterThan(pixels.at(10, 2).r, 200)
    XCTAssertGreaterThan(pixels.at(10, 17).b, 200)
  }

  func testPreviewsAreScaledAndExportsAreNot() throws {
    let url = try makePNG("big.png", width: 400, height: 200, paint: grey(0.4))
    _ = try engine.open(id: "a", url: url)
    let (preview, _) = try render("a", maxEdge: 100)
    XCTAssertEqual(preview, Size(width: 100, height: 50))
    let (full, _) = try render("a", maxEdge: 0)
    XCTAssertEqual(full, Size(width: 400, height: 200))
  }

  func testExportWritesAFullResolutionFile() throws {
    let url = try makePNG("big.png", width: 400, height: 200, paint: grey(0.4))
    let original = try Data(contentsOf: url)
    _ = try engine.open(id: "a", url: url)
    var recipe = RenderRecipe()
    recipe.rotation = 90
    let target = directory.appendingPathComponent("export.jpg")
    let size = try engine.export(id: "a", recipe: recipe, to: target)
    XCTAssertEqual(size.width, 200)
    XCTAssertEqual(size.height, 400)
    let written = try XCTUnwrap(CGImageSourceCreateWithURL(target as CFURL, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(written, 0, nil))
    XCTAssertEqual(image.width, 200)
    XCTAssertEqual(image.height, 400)
    // The original is only ever read.
    XCTAssertEqual(try Data(contentsOf: url), original)
  }

  /// A full-size export is developed in bands. Across the seams it must be the very picture
  /// developed whole, with blurs, halation and a grown, feathered local adjustment reaching over them,
  /// and it keeps the original's capture details.
  func testAnExportDevelopedInBandsIsThePictureDevelopedWhole() throws {
    // Stripes and a gradient, so a misplaced or cut-off band would show.
    let url = try makePNG("bands.png", width: 240, height: 360) { x, y in
      let stripe = (x / 12 + y / 20) % 2 == 0 ? 0.25 : 0.0
      return (0.2 + stripe + Double(x) / 600, 0.3 + Double(y) / 900, 0.6 - stripe)
    }
    _ = try engine.open(id: "a", url: url)
    var recipe = RenderRecipe()
    recipe.exposureEV = 0.3
    recipe.localContrast = [.init(radius: 0.05, intensity: 0.6)]
    recipe.halation = .init(strength: 0.5, radius: 0.04, threshold: 0.3, color: [1, 0.4, 0.2])
    var lift = RenderRecipe.LocalPass(
      mask: try Mask.parse("mask", ["area": ["type": "radial", "x": 0.5, "y": 0.45, "width": 0.6, "height": 0.4, "feather": 0.5], "grow": 0.03]))
    lift.gains = [1.4, 1.1, 0.8]
    recipe.local = [lift]
    recipe.vignette = 0.4

    let saved = Engine.exportBandPixels
    defer { Engine.exportBandPixels = saved }
    func export(bandPixels: Int, to name: String) throws -> CGImageSource {
      Engine.exportBandPixels = bandPixels
      let target = directory.appendingPathComponent(name)
      let size = try engine.export(id: "a", recipe: recipe, to: target)
      XCTAssertEqual(size.width, 240)
      XCTAssertEqual(size.height, 360)
      return try XCTUnwrap(CGImageSourceCreateWithURL(target as CFURL, nil))
    }
    let once = try export(bandPixels: 1 << 40, to: "whole.jpg")
    let written = try export(bandPixels: 240 * 50, to: "bands.jpg")  // eight bands, the last one short
    func pixels(_ source: CGImageSource) throws -> [UInt8] {
      let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
      var data = [UInt8](repeating: 0, count: 240 * 360 * 4)
      let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
      let context = try XCTUnwrap(
        CGContext(data: &data, width: 240, height: 360, bitsPerComponent: 8, bytesPerRow: 240 * 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
      context.draw(image, in: CGRect(x: 0, y: 0, width: 240, height: 360))
      return data
    }
    let a = try pixels(once)
    let b = try pixels(written)
    var worst = 0
    var total = 0
    for index in 0..<a.count where index % 4 != 3 {
      let difference = abs(Int(a[index]) - Int(b[index]))
      worst = max(worst, difference)
      total += difference
    }
    XCTAssertLessThan(Double(total) / Double(240 * 360 * 3), 0.3, "developed in bands, it is the picture developed whole")
    // A band out of place by even a row would differ by 50 or more at the stripes' edges; the
    // JPEG's own rounding of near-equal pictures stays within a few levels.
    XCTAssertLessThanOrEqual(worst, 16, "and no seam or band out of place shows")

    let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(written, 0, nil) as? [String: Any])
    XCTAssertEqual(properties[kCGImagePropertyOrientation as String] as? Int ?? 1, 1)
    XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int, 240)
  }

  /// On a large render (a zoom into part of a big photo, an export) a mask that snaps to the
  /// photo's edges is worked out on a small development, rather than by developing the whole frame
  /// at full size. It must be the same mask: a zoom into a corner looks like that corner of the
  /// whole photo.
  func testAZoomIntoABigPhotoSnapsMasksAsTheWholePhotoDoes() throws {
    // 4096 × 3072: a hard edge for the mask to snap to, and texture.
    let url = try makePNG("big-edge.png", width: 4096, height: 3072) { x, y in
      let base = x < 1500 ? 0.75 : 0.2
      return (base, base * 0.9 + Double((x / 64 + y / 64) % 2) * 0.05, base * 0.8)
    }
    _ = try engine.open(id: "b", url: url)
    var recipe = RenderRecipe()
    // A soft gradient across the edge, snapped to it, darkening what it covers.
    var pass = RenderRecipe.LocalPass(
      mask: try Mask.parse("mask", ["area": ["type": "linear", "from": [0.3, 0.5], "to": [0.45, 0.5]], "refine": 1]))
    pass.gains = [0.4, 0.4, 0.4]
    recipe.local = [pass]
    // The whole photo at preview size (masks worked out directly), and its top-left quarter at
    // twice that (the frame then 4096 across: masks worked out small).
    let whole = try render("b", recipe, maxEdge: 2048).1
    let zoom = try render("b", recipe, maxEdge: 2048, region: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)).1
    // `render` reads both back at 512 across: the zoom's (x, y) is the whole's (x / 2, y / 2).
    XCTAssertEqual(whole.width, 512)
    XCTAssertEqual(zoom.width, 512)
    var total = 0.0
    var count = 0.0
    for y in stride(from: 2, to: zoom.height - 2, by: 3) {
      for x in stride(from: 2, to: zoom.width - 2, by: 3) {
        let a = whole.at(x / 2, y / 2)
        let b = zoom.at(x, y)
        total += Double(abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b)) / 3
        count += 1
      }
    }
    XCTAssertLessThan(total / count, 8, "the corner, zoomed, is that corner of the whole photo")
    // The snapped mask darkens up to the photo's edge (1500 of 4096 across, so 0.73 of the zoom):
    // just left of it is the bright side darkened (undarkened it would be about 190).
    let edge = Int(0.732 * Double(zoom.width))
    XCTAssertLessThan(zoom.at(edge - 12, zoom.height / 2).r, 160)
  }

  func testTheCaptureDetailsOfARawAreMadeTrueOfItsJPEG() {
    let source: [String: Any] = [
      kCGImagePropertyPixelWidth as String: 4032, kCGImagePropertyDepth as String: 16, kCGImagePropertyOrientation as String: 6,
      kCGImagePropertyDNGDictionary as String: ["DNGVersion": [1, 4, 0, 0]],
      kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFOrientation as String: 6, kCGImagePropertyTIFFModel as String: "iPhone", kCGImagePropertyTIFFCompression as String: 7],
      kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifISOSpeedRatings as String: [1600], kCGImagePropertyExifPixelXDimension as String: 4032],
    ]
    let made = Engine.exportProperties(source, width: 3024, height: 4032, quality: 0.95)
    XCTAssertNil(made[kCGImagePropertyPixelWidth as String])
    XCTAssertNil(made[kCGImagePropertyDepth as String])
    XCTAssertNil(made[kCGImagePropertyDNGDictionary as String], "the sensor's layout is not the JPEG's")
    XCTAssertEqual(made[kCGImagePropertyOrientation as String] as? Int, 1, "the turn is in the pixels")
    let tiff = made[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
    XCTAssertEqual(tiff?[kCGImagePropertyTIFFOrientation as String] as? Int, 1)
    XCTAssertEqual(tiff?[kCGImagePropertyTIFFModel as String] as? String, "iPhone", "the camera is still named")
    XCTAssertNil(tiff?[kCGImagePropertyTIFFCompression as String])
    let exif = made[kCGImagePropertyExifDictionary as String] as? [String: Any]
    XCTAssertEqual(exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [Int], [1600], "and how it was taken")
    XCTAssertEqual(exif?[kCGImagePropertyExifPixelXDimension as String] as? Int, 3024)
  }

  func testThePictureForTheModelIsAJPEGOfTheRequestedSize() throws {
    let url = try makePNG("big.png", width: 400, height: 200, paint: grey(0.4))
    _ = try engine.open(id: "a", url: url)
    let data = try engine.jpeg(id: "a", recipe: RenderRecipe(), options: RenderOptions(maxEdge: 200))
    XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8])
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    XCTAssertEqual(image.width, 200)
    XCTAssertEqual(image.height, 100)
  }

  func testARegionZoomsIntoPartOfTheFrame() throws {
    // Left half red, right half blue; the top-right quarter is asked for.
    let url = try makePNG("sides.png", width: 400, height: 200) { x, _ in x < 200 ? (1, 0, 0) : (0, 0, 1) }
    _ = try engine.open(id: "a", url: url)
    let (size, pixels) = try render("a", maxEdge: 0, region: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
    XCTAssertEqual(size, Size(width: 200, height: 100))
    XCTAssertGreaterThan(pixels.at(10, 10).b, 200)
    XCTAssertLessThan(pixels.at(10, 10).r, 60)
    // A small region of a large photo comes back at up to the requested size, from full-resolution data.
    let (zoomed, _) = try render("a", maxEdge: 50, region: CGRect(x: 0, y: 0, width: 0.25, height: 0.25))
    XCTAssertEqual(zoomed, Size(width: 50, height: 25))
  }

  // MARK: Light

  func testExposureWorksInLinearLight() throws {
    let url = try makePNG("grey.png", width: 16, height: 16, paint: grey(0.5))
    _ = try engine.open(id: "a", url: url)
    var recipe = RenderRecipe()
    recipe.exposureEV = 1
    let (_, pixels) = try render("a", recipe)
    // sRGB 0.5 is 0.214 linear; one stop up is 0.428 linear, which is sRGB 0.686 (175).
    // Doubling the encoded value instead would give 255.
    XCTAssertEqual(pixels.mean.g, 175, accuracy: 4)
  }

  func testShadowAndHighlightRecoveryMoveTheRightWay() throws {
    let url = try makePNG("split.png", width: 64, height: 64) { x, _ in x < 32 ? (0.12, 0.12, 0.12) : (0.92, 0.92, 0.92) }
    _ = try engine.open(id: "a", url: url)
    let (_, before) = try render("a")
    var recipe = RenderRecipe()
    recipe.shadowAmount = 0.8
    recipe.highlightAmount = 0.3
    let (_, after) = try render("a", recipe)
    XCTAssertGreaterThan(after.at(8, 32).g, before.at(8, 32).g + 3, "shadows should open")
    XCTAssertLessThan(after.at(56, 32).g, before.at(56, 32).g - 3, "highlights should come down")
  }

  func testLocalContrastLeavesFlatAreasAlone() throws {
    let url = try makePNG("grey.png", width: 64, height: 64, paint: grey(0.5))
    _ = try engine.open(id: "a", url: url)
    var recipe = RenderRecipe()
    recipe.localContrast = [.init(radius: 0.02, intensity: 0.7), .init(radius: 0.003, intensity: -0.6)]
    let (_, pixels) = try render("a", recipe)
    XCTAssertEqual(pixels.at(32, 32).g, 128, accuracy: 3)
    XCTAssertEqual(pixels.at(1, 1).g, 128, accuracy: 3)
  }

  // MARK: White balance

  func testHigherTemperatureIsWarmerAndPositiveTintIsMagenta() throws {
    let url = try makePNG("grey.png", width: 16, height: 16, paint: grey(0.5))
    _ = try engine.open(id: "a", url: url)
    var warm = RenderRecipe()
    warm.temperature = 9000
    warm.tint = 0
    let warmMean = try render("a", warm).1.mean
    XCTAssertGreaterThan(warmMean.r, warmMean.b + 5, "a higher temperature should warm the photo")

    var cool = RenderRecipe()
    cool.temperature = 4500
    cool.tint = 0
    let coolMean = try render("a", cool).1.mean
    XCTAssertGreaterThan(coolMean.b, coolMean.r + 5, "a lower temperature should cool the photo")

    var magenta = RenderRecipe()
    magenta.temperature = 6500
    magenta.tint = 60
    let magentaMean = try render("a", magenta).1.mean
    XCTAssertLessThan(magentaMean.g, (magentaMean.r + magentaMean.b) / 2 - 3, "a positive tint should be magenta")
  }

  // MARK: Tables

  func testToneTableIsAppliedPerChannel() throws {
    let url = try makePNG("grey.png", width: 16, height: 16, paint: grey(0.25))
    _ = try engine.open(id: "a", url: url)
    // Red inverted, green untouched, blue forced to zero, in Display P3.
    let size = 1024
    var table: [Float] = []
    for index in 0..<size {
      let x = Float(index) / Float(size - 1)
      table += [1 - x, x, 0]
    }
    var recipe = RenderRecipe()
    recipe.toneTableSize = size
    recipe.toneTable = floats(table)
    let (_, pixels) = try render("a", recipe)
    let pixel = pixels.at(8, 8)
    // The grey is (0.25, 0.25, 0.25) in P3 too, so the table gives P3 (0.75, 0.25, 0).
    // Read back as sRGB that is a more saturated (0.81, 0.20, 0): the tables work in P3, not sRGB.
    XCTAssertEqual(pixel.r, 207, accuracy: 4)
    XCTAssertEqual(pixel.g, 50, accuracy: 4)
    XCTAssertLessThan(pixel.b, 12)
  }

  func testToneTableLookupIsFineEnoughForSmoothGradients() throws {
    let url = try makePNG("ramp.png", width: 256, height: 4) { x, _ in
      let value = Double(x) / 255
      return (value, value, value)
    }
    _ = try engine.open(id: "a", url: url)
    let size = 1024
    var table: [Float] = []
    for index in 0..<size {
      let x = Float(index) / Float(size - 1)
      table += [x, x, x]
    }
    var recipe = RenderRecipe()
    recipe.toneTableSize = size
    recipe.toneTable = floats(table)
    let (_, pixels) = try render("a", recipe)
    for x in stride(from: 0, to: 256, by: 5) {
      XCTAssertEqual(pixels.at(x, 2).g, x, accuracy: 1, "identity table at \(x)")
    }
  }

  func testColourCubeHasRedVaryingFastest() throws {
    let url = try makePNG("red.png", width: 16, height: 16) { _, _ in (0.8, 0.1, 0.1) }
    _ = try engine.open(id: "a", url: url)
    // Keep only the red coordinate. If blue varied fastest this would keep blue and give black.
    let size = 9
    var cube: [Float] = []
    for _ in 0..<size {
      for _ in 0..<size {
        for r in 0..<size {
          cube += [Float(r) / Float(size - 1), 0, 0, 1]
        }
      }
    }
    var recipe = RenderRecipe()
    recipe.cubeSize = size
    recipe.cube = floats(cube)
    let (_, pixels) = try render("a", recipe)
    let pixel = pixels.at(8, 8)
    XCTAssertGreaterThan(pixel.r, 150)
    XCTAssertLessThan(pixel.g, 60)
    XCTAssertLessThan(pixel.b, 60)
  }

  func testIdentityTablesChangeNothing() throws {
    let url = try makePNG("colour.png", width: 16, height: 16) { _, _ in (0.7, 0.4, 0.2) }
    _ = try engine.open(id: "a", url: url)
    let size = 33
    var cube: [Float] = []
    for b in 0..<size {
      for g in 0..<size {
        for r in 0..<size {
          cube += [Float(r) / Float(size - 1), Float(g) / Float(size - 1), Float(b) / Float(size - 1), 1]
        }
      }
    }
    var table: [Float] = []
    for index in 0..<256 {
      let x = Float(index) / 255
      table += [x, x, x]
    }
    var recipe = RenderRecipe()
    recipe.cubeSize = size
    recipe.cube = floats(cube)
    recipe.toneTableSize = 256
    recipe.toneTable = floats(table)
    let (_, pixels) = try render("a", recipe)
    let pixel = pixels.at(8, 8)
    XCTAssertEqual(pixel.r, 179, accuracy: 3)
    XCTAssertEqual(pixel.g, 102, accuracy: 3)
    XCTAssertEqual(pixel.b, 51, accuracy: 3)
  }

  // MARK: Geometry

  private func leftRedRightBlue() throws -> URL {
    try makePNG("sides.png", width: 80, height: 40) { x, _ in x < 40 ? (1, 0, 0) : (0, 0, 1) }
  }

  func testRotationIsClockwise() throws {
    _ = try engine.open(id: "a", url: try leftRedRightBlue())
    var recipe = RenderRecipe()
    recipe.rotation = 90
    let (result, pixels) = try render("a", recipe)
    XCTAssertEqual(result, Size(width: 40, height: 80))
    // Turning clockwise brings the left side to the top.
    XCTAssertGreaterThan(pixels.at(20, 10).r, 200)
    XCTAssertGreaterThan(pixels.at(20, 70).b, 200)
  }

  func testFlipAndCrop() throws {
    _ = try engine.open(id: "a", url: try leftRedRightBlue())
    var flipped = RenderRecipe()
    flipped.flipHorizontal = true
    XCTAssertGreaterThan(try render("a", flipped).1.at(10, 20).b, 200)

    var cropped = RenderRecipe()
    cropped.cropX = 0.5
    cropped.cropWidth = 0.5
    cropped.cropY = 0.25
    cropped.cropHeight = 0.5
    let (result, pixels) = try render("a", cropped)
    XCTAssertEqual(result, Size(width: 40, height: 20))
    XCTAssertGreaterThan(pixels.at(2, 2).b, 200)

    let (whole, _) = try render("a", cropped, fullFrame: true)
    XCTAssertEqual(whole, Size(width: 80, height: 40))
  }

  func testCropMeasuresFromTheTop() throws {
    let url = try makePNG("halves.png", width: 40, height: 40) { _, y in y < 20 ? (1, 0, 0) : (0, 0, 1) }
    _ = try engine.open(id: "a", url: url)
    var recipe = RenderRecipe()
    recipe.cropY = 0
    recipe.cropHeight = 0.4
    let (_, pixels) = try render("a", recipe)
    XCTAssertGreaterThan(pixels.at(20, 8).r, 200)
  }

  func testStraighteningTrimsEmptyCorners() throws {
    let url = try makePNG("white.png", width: 120, height: 80, paint: grey(1))
    _ = try engine.open(id: "a", url: url)
    var recipe = RenderRecipe()
    recipe.angle = 10
    let (result, pixels) = try render("a", recipe)
    let trim = Engine.straightenScale(angle: 10, size: CGSize(width: 120, height: 80))
    XCTAssertEqual(Double(result.width), 120 * Double(trim), accuracy: 2)
    XCTAssertEqual(Double(result.height), 80 * Double(trim), accuracy: 2)
    for (x, y) in [(1, 1), (pixels.width - 2, 1), (1, pixels.height - 2), (pixels.width - 2, pixels.height - 2)] {
      XCTAssertGreaterThan(pixels.at(x, y).g, 235, "corner \(x),\(y) should be photo, not empty")
    }
  }

  func testVignetteDarkensOrLightensTheCorners() throws {
    let url = try makePNG("grey.png", width: 80, height: 60, paint: grey(0.5))
    _ = try engine.open(id: "a", url: url)
    var dark = RenderRecipe()
    dark.vignette = 1
    let darkened = try render("a", dark).1
    XCTAssertEqual(darkened.at(40, 30).g, 128, accuracy: 4)
    XCTAssertLessThan(darkened.at(1, 1).g, 100)

    var light = RenderRecipe()
    light.vignette = -1
    let lightened = try render("a", light).1
    XCTAssertGreaterThan(lightened.at(1, 1).g, 150)
  }

  // MARK: RAW

  /// An uncompressed DNG of a flat mid-grey scene: a Bayer mosaic, or already demosaiced
  /// ("linear", as Apple ProRAW is). `extended` adds the optional tags real cameras write.
  /// Apple's decoder ignores very small files (64 × 48 comes back empty), hence the size.
  private func makeDNG(_ name: String, width: Int = 320, height: Int = 240, linear: Bool = false, extended: Bool = false, level: UInt16 = 11796) throws -> URL {
    var extra = Data()
    var entries: [(tag: UInt16, type: UInt16, count: UInt32, value: Data)] = []
    func bytes<T: FixedWidthInteger>(_ value: T) -> Data {
      withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
    func add(_ tag: UInt16, _ type: UInt16, _ count: Int, _ value: Data) {
      entries.append((tag, type, UInt32(count), value))
    }
    func short(_ tag: UInt16, _ values: [UInt16]) {
      add(tag, 3, values.count, values.reduce(Data()) { $0 + bytes($1) })
    }
    func long(_ tag: UInt16, _ values: [UInt32]) {
      add(tag, 4, values.count, values.reduce(Data()) { $0 + bytes($1) })
    }
    func byte(_ tag: UInt16, _ values: [UInt8]) {
      add(tag, 1, values.count, Data(values))
    }
    func ascii(_ tag: UInt16, _ text: String) {
      let data = Data(text.utf8) + Data([0])
      add(tag, 2, data.count, data)
    }
    func rational(_ tag: UInt16, signed: Bool, _ values: [Double]) {
      var data = Data()
      for value in values {
        data += bytes(Int32((value * 10000).rounded()))
        data += bytes(Int32(10000))
      }
      add(tag, signed ? 10 : 5, values.count, data)
    }

    let samples = linear ? 3 : 1
    let pixelBytes = width * height * 2 * samples
    long(254, [0])
    long(256, [UInt32(width)])
    long(257, [UInt32(height)])
    short(258, [UInt16](repeating: 16, count: samples))
    short(259, [1])
    short(262, [linear ? 34892 : 32803])
    ascii(271, "Oscuru")
    ascii(272, "Test Camera")
    long(273, [0])  // strip offset, patched below
    short(274, [1])
    short(277, [UInt16(samples)])
    long(278, [UInt32(height)])
    long(279, [UInt32(pixelBytes)])
    short(284, [1])
    if !linear {
      short(33421, [2, 2])
      byte(33422, [0, 1, 1, 2])
    }
    byte(50706, [1, 4, 0, 0])
    byte(50707, [1, 1, 0, 0])
    ascii(50708, "Oscuru Test Camera")
    long(50717, [UInt32](repeating: 65535, count: samples))
    // XYZ (D65) to linear sRGB, so the "camera" sees sRGB primaries.
    rational(50721, signed: true, [3.2406, -1.5372, -0.4986, -0.9689, 1.8758, 0.0415, 0.0557, -0.2040, 1.0570])
    rational(50728, signed: false, [1, 1, 1])
    short(50778, [21])
    if extended {
      if !linear {
        byte(50710, [0, 1, 2])
        short(50711, [1])
      }
      short(50713, [1, 1])
      long(50714, [UInt32](repeating: 0, count: samples))
      rational(50718, signed: false, [1, 1])
      long(50719, [0, 0])
      long(50720, [UInt32(width), UInt32(height)])
      rational(50727, signed: false, [1, 1, 1])
      rational(50730, signed: true, [0])
      rational(50731, signed: false, [1])
      rational(50732, signed: false, [1])
      rational(50734, signed: false, [1])
      long(50829, [0, 0, UInt32(height), UInt32(width)])
    }
    entries.sort { $0.tag < $1.tag }

    let headerSize = 8
    let directorySize = 2 + entries.count * 12 + 4
    let extraStart = headerSize + directorySize
    var ifd = Data()
    ifd += bytes(UInt16(entries.count))
    var stripOffsetPosition = 0
    for entry in entries {
      ifd += bytes(entry.tag)
      ifd += bytes(entry.type)
      ifd += bytes(entry.count)
      if entry.tag == 273 { stripOffsetPosition = headerSize + ifd.count }
      if entry.value.count <= 4 {
        ifd += entry.value + Data(count: 4 - entry.value.count)
      } else {
        ifd += bytes(UInt32(extraStart + extra.count))
        extra += entry.value
        if extra.count % 2 == 1 { extra += Data([0]) }
      }
    }
    ifd += bytes(UInt32(0))

    var file = Data([0x49, 0x49]) + bytes(UInt16(42)) + bytes(UInt32(headerSize))
    file += ifd
    file += extra
    let stripOffset = UInt32(file.count)
    file.replaceSubrange(stripOffsetPosition..<(stripOffsetPosition + 4), with: bytes(stripOffset))
    var pixels = Data(capacity: pixelBytes)
    for _ in 0..<(width * height * samples) {
      pixels += bytes(level)
    }
    file += pixels
    let url = directory.appendingPathComponent(name)
    try file.write(to: url)
    return url
  }

  // MARK: Grain, halation, local adjustments

  private func recipe(_ change: (inout EditingState) throws -> Void) throws -> RenderRecipe {
    var state = EditingState()
    try change(&state)
    return RenderRecipe(state: state, defaults: PhotoDefaults())
  }

  private func spread(_ pixels: Pixels) -> Double {
    let mean = pixels.mean.g
    var sum = 0.0
    for y in 0..<pixels.height {
      for x in 0..<pixels.width {
        let d = Double(pixels.at(x, y).g) - mean
        sum += d * d
      }
    }
    return (sum / Double(pixels.width * pixels.height)).squareRoot()
  }

  func testGrainAddsTextureWithoutChangingBrightnessTheSameEveryTime() throws {
    _ = try engine.open(id: "g", url: try makePNG("grey.png", width: 400, height: 300, paint: grey(0.5)))
    let (_, plain) = try render("g")
    let grainy = try recipe { try $0.setGrain(["amount": 60, "size": 100]) }
    let (_, first) = try render("g", grainy)
    XCTAssertLessThan(spread(plain), 1)
    XCTAssertGreaterThan(spread(first), 3, "grain shows")
    XCTAssertEqual(first.mean.g, plain.mean.g, accuracy: 3, "grain does not brighten or darken")
    XCTAssertEqual(try render("g", grainy).1.data, first.data, "the same grain every time")
  }

  func testHalationGlowsRedAroundBrightAreasOnly() throws {
    let url = try makePNG("lamp.png", width: 400, height: 300) { x, y in
      (150..<250).contains(x) && (100..<200).contains(y) ? (1, 1, 1) : (0.15, 0.15, 0.15)
    }
    _ = try engine.open(id: "h", url: url)
    let (_, plain) = try render("h")
    let (_, glowing) = try render("h", try recipe { try $0.setHalation(["amount": 80, "radius": 60]) })
    let near = (before: plain.at(140, 150), after: glowing.at(140, 150))
    XCTAssertGreaterThan(near.after.r, near.before.r + 8, "light spreads just outside the bright area")
    XCTAssertGreaterThan(near.after.r - near.after.b, near.before.r - near.before.b + 5, "and it is red")
    XCTAssertEqual(Double(glowing.at(10, 10).r), Double(plain.at(10, 10).r), accuracy: 2, "far away nothing changes")
  }

  func testARadialAdjustmentChangesItsAreaOnly() throws {
    _ = try engine.open(id: "r", url: try makePNG("mid.png", width: 400, height: 300, paint: grey(0.4)))
    let (_, plain) = try render("r")
    let lit = try recipe {
      try $0.setLocal(
        name: "middle", settings: ["mask": ["area": ["type": "radial", "x": 0.5, "y": 0.5, "width": 0.5, "height": 0.5, "feather": 0.2]], "adjust": ["exposureEV": 1]])
    }
    let (_, result) = try render("r", lit)
    XCTAssertGreaterThan(result.at(200, 150).g, plain.at(200, 150).g + 25)
    XCTAssertEqual(Double(result.at(10, 10).g), Double(plain.at(10, 10).g), accuracy: 1)
    XCTAssertEqual(Double(result.at(390, 290).g), Double(plain.at(390, 290).g), accuracy: 1)
  }

  func testALinearGradientFadesFromItsStartToItsEnd() throws {
    _ = try engine.open(id: "s", url: try makePNG("sky.png", width: 400, height: 300, paint: grey(0.6)))
    let (_, plain) = try render("s")
    let sky = try recipe { try $0.setLocal(name: "sky", settings: ["mask": ["area": ["type": "linear", "from": [0.5, 0], "to": [0.5, 0.5]]], "adjust": ["exposureEV": -1]]) }
    let (_, result) = try render("s", sky)
    XCTAssertLessThan(result.at(200, 2).g, plain.at(200, 2).g - 20, "full strength at the top")
    XCTAssertLessThan(result.at(200, 75).g, plain.at(200, 75).g - 5, "fading")
    XCTAssertEqual(Double(result.at(200, 290).g), Double(plain.at(200, 290).g), accuracy: 1, "nothing past the end")
  }

  func testRangesNarrowAMaskToTonesAndColours() throws {
    let url = try makePNG("halves.png", width: 400, height: 300) { x, y in
      if y < 150 { return x < 200 ? (0.2, 0.2, 0.2) : (0.8, 0.8, 0.8) }
      return x < 200 ? (0.8, 0.15, 0.1) : (0.15, 0.7, 0.2)
    }
    _ = try engine.open(id: "q", url: url)
    let (_, plain) = try render("q")
    let bright = try recipe { try $0.setLocal(name: "bright", settings: ["mask": ["area": ["type": "frame"], "luminance": ["from": 0.6, "to": 1]], "adjust": ["exposureEV": -1]]) }
    let (_, toned) = try render("q", bright)
    XCTAssertLessThan(toned.at(300, 50).g, plain.at(300, 50).g - 20, "bright tones change")
    XCTAssertEqual(Double(toned.at(100, 50).g), Double(plain.at(100, 50).g), accuracy: 2, "dark tones do not")

    let reds = try recipe { try $0.setLocal(name: "reds", settings: ["mask": ["area": ["type": "frame"], "color": ["hue": 0, "range": 60]], "adjust": ["saturation": -100]]) }
    let (_, muted) = try render("q", reds)
    let red = muted.at(100, 220)
    XCTAssertLessThan(red.r - red.b, (plain.at(100, 220).r - plain.at(100, 220).b) / 3, "red loses its colour")
    XCTAssertEqual(Double(muted.at(300, 220).g), Double(plain.at(300, 220).g), accuracy: 2, "green keeps its own")
  }

  func testAMaskPreviewPaintsItsAreaAndSaysHowMuchItCovers() throws {
    _ = try engine.open(id: "m", url: try makePNG("plain.png", width: 400, height: 300, paint: grey(0.5)))
    let ellipse = try Mask.parse("mask", ["area": ["type": "radial", "x": 0.5, "y": 0.5, "width": 0.5, "height": 0.5, "feather": 0]])
    let preview = try engine.maskPreview(id: "m", recipe: RenderRecipe(), mask: ellipse, options: RenderOptions(maxEdge: 512))
    XCTAssertFalse(preview.jpeg.isEmpty)
    XCTAssertEqual(preview.coverage, Double.pi * 0.25 * 0.25, accuracy: 0.03)

    let nothing = try Mask.parse("mask", ["area": ["type": "frame"], "invert": true])
    XCTAssertEqual(try engine.maskPreview(id: "m", recipe: RenderRecipe(), mask: nothing, options: RenderOptions(maxEdge: 256)).coverage, 0, accuracy: 0.001)

    // A plain grey has no subject: the mask is empty, not an error.
    let subject = try Mask.parse("mask", ["area": ["type": "subject"]])
    let found = try engine.maskPreview(id: "m", recipe: RenderRecipe(), mask: subject, options: RenderOptions(maxEdge: 256))
    XCTAssertGreaterThanOrEqual(found.coverage, 0)
    XCTAssertLessThanOrEqual(found.coverage, 1)
  }

  private func coverage(_ id: String, _ mask: JSONValue, recipe: RenderRecipe = RenderRecipe(), engine: Engine? = nil) throws -> Double {
    let target: Engine = engine ?? self.engine
    return try target.maskPreview(id: id, recipe: recipe, mask: try Mask.parse("mask", mask), options: RenderOptions(maxEdge: 400)).coverage
  }

  func testJoinedAreasNeverDoubleAndCanBeCutOutOrIntersected() throws {
    _ = try engine.open(id: "j", url: try makePNG("grey.png", width: 400, height: 300, paint: grey(0.4)))
    let left: JSONValue = ["type": "outline", "points": [[0, 0], [0.6, 0], [0.6, 1], [0, 1]], "feather": 0]
    let right: JSONValue = ["type": "outline", "points": [[0.4, 0], [1, 0], [1, 1], [0.4, 1]], "feather": 0]
    XCTAssertEqual(try coverage("j", ["area": left]), 0.6, accuracy: 0.02)
    XCTAssertEqual(try coverage("j", ["area": [left, right]]), 1, accuracy: 0.02, "joined, the overlap counts once")
    XCTAssertEqual(try coverage("j", ["area": left, "subtract": right]), 0.4, accuracy: 0.02)
    XCTAssertEqual(try coverage("j", ["area": left, "intersect": right]), 0.2, accuracy: 0.02)

    // Where two joined areas overlap, the change is the same as where only one is.
    let joined = try recipe { try $0.setLocal(name: "both", settings: ["mask": ["area": [left, right]], "adjust": ["exposureEV": 1]]) }
    let (_, result) = try render("j", joined)
    XCTAssertEqual(Double(result.at(200, 150).g), Double(result.at(40, 150).g), accuracy: 2)
  }

  func testOutlinesAndBrushStrokesAreDrawnWhereTheySay() throws {
    _ = try engine.open(id: "d", url: try makePNG("grey.png", width: 400, height: 300, paint: grey(0.4)))
    let square: JSONValue = ["type": "outline", "points": [[0.25, 0.25], [0.75, 0.25], [0.75, 0.75], [0.25, 0.75]], "feather": 0]
    XCTAssertEqual(try coverage("d", ["area": square]), 0.25, accuracy: 0.02)
    let lit = try recipe { try $0.setLocal(name: "square", settings: ["mask": ["area": square], "adjust": ["exposureEV": 1]]) }
    let (_, plain) = try render("d")
    let (_, result) = try render("d", lit)
    XCTAssertGreaterThan(result.at(200, 150).g, plain.at(200, 150).g + 25, "inside")
    XCTAssertEqual(Double(result.at(40, 40).g), Double(plain.at(40, 40).g), accuracy: 1, "outside, top left")
    XCTAssertEqual(Double(result.at(200, 30).g), Double(plain.at(200, 30).g), accuracy: 1, "outside, above: measured from the top")

    // A stroke across the middle, a tenth of the long edge thick, and a dot.
    let stroke: JSONValue = ["type": "brush", "strokes": [[[0.1, 0.5], [0.9, 0.5]]], "size": 0.1, "feather": 0]
    let frameArea: Double = 400 * 300
    let band: Double = 320 * 40  // the stroke's straight part
    let caps: Double = Double.pi * 20 * 20  // its two round ends
    XCTAssertEqual(try coverage("d", ["area": stroke]), (band + caps) / frameArea, accuracy: 0.02)
    let dot: JSONValue = ["type": "brush", "strokes": [[[0.5, 0.2]]], "size": 0.1, "feather": 0]
    XCTAssertEqual(try coverage("d", ["area": dot]), caps / frameArea, accuracy: 0.005)
    // A brush cuts what a shape spilled into.
    let crossing: Double = 200 * 40  // where the stroke crosses the square
    XCTAssertEqual(try coverage("d", ["area": square, "subtract": stroke]), 0.25 - crossing / frameArea, accuracy: 0.02)
  }

  func testRangesCanBeMeasuredOnThePhotoBeforeItsStyle() throws {
    let url = try makePNG("leaves.png", width: 400, height: 300) { x, _ in x < 200 ? (0.8, 0.15, 0.1) : (0.15, 0.7, 0.2) }
    _ = try engine.open(id: "o", url: url)
    // A style that turns everything grey: on the photo as it is now, nothing is red any more.
    let grey = try recipe { try $0.adjust(["saturation": -100]) }
    XCTAssertLessThan(try coverage("o", ["area": ["type": "frame"], "color": ["hue": 0, "range": 60]], recipe: grey), 0.05)
    XCTAssertEqual(try coverage("o", ["area": ["type": "frame"], "color": ["hue": 0, "range": 60], "measure": "original"], recipe: grey), 0.5, accuracy: 0.05)
  }

  func testMasksGrowShrinkAndSnapToEdges() throws {
    _ = try engine.open(id: "e", url: try makePNG("grey.png", width: 400, height: 300, paint: grey(0.4)))
    let square: JSONValue = ["type": "outline", "points": [[0.25, 0.25], [0.75, 0.25], [0.75, 0.75], [0.25, 0.75]], "feather": 0]
    let base = try coverage("e", ["area": square])
    XCTAssertGreaterThan(try coverage("e", ["area": square, "grow": 0.02]), base + 0.02)
    XCTAssertLessThan(try coverage("e", ["area": square, "grow": -0.02]), base - 0.02)

    // A soft gradient across a hard edge in the photo steps at that edge once refined.
    let photo = CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 210, height: 300))
      .composited(over: CIImage(color: CIColor(red: 0.9, green: 0.9, blue: 0.9)).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300)))
    let gradient = try Mask.parse("mask", ["area": ["type": "linear", "from": [0.55, 0.5], "to": [0.45, 0.5]]])
    var refinedMask = gradient
    refinedMask.refine = 0.6
    func value(_ mask: Mask, x: Int) -> Double {
      let image = Effects.mask(mask, over: photo, original: { photo }, found: { _ in nil }, depth: { _ in nil }, context: engine.context)
      var pixel = [UInt8](repeating: 0, count: 4)
      engine.context.render(image, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: x, y: 150, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
      return Double(pixel[0]) / 255
    }
    XCTAssertLessThan(value(gradient, x: 212) - value(gradient, x: 207), 0.15)
    XCTAssertGreaterThan(value(refinedMask, x: 212) - value(refinedMask, x: 207), 0.25, "the step moves onto the photo's edge")
    XCTAssertEqual(value(refinedMask, x: 20), 0, accuracy: 0.02)
    XCTAssertEqual(value(refinedMask, x: 380), 1, accuracy: 0.02)
  }

  /// The folder holding the model `name`, when it has been fetched (scripts/fetch-models.sh).
  private func models(with name: String) -> URL? {
    let ios = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    for folder in ["Models", "ModelSources"] {
      let url = ios.appendingPathComponent(folder)
      if FileManager.default.fileExists(atPath: url.appendingPathComponent("\(name).mlmodelc").path)
        || FileManager.default.fileExists(atPath: url.appendingPathComponent("\(name).mlpackage").path)
      {
        return url
      }
    }
    return nil
  }

  func testDepthRangesKeepWhatIsFarAndShowTheirScale() throws {
    guard let models = models(with: DepthEstimator.name) else { throw XCTSkip("the depth model has not been fetched (scripts/fetch-models.sh)") }
    let measuring = Engine(useSoftwareRenderer: true, models: models)
    // Checkered ground receding to a horizon two fifths of the way down, sky above.
    let horizon: Double = 0.4 * 384
    let url = try makePNG("ground.png", width: 512, height: 384) { x, y in
      let row = Double(y)
      if row < horizon {
        let t: Double = row / horizon
        return (0.55 + 0.35 * t, 0.7 + 0.25 * t, 0.95)
      }
      let distance: Double = 40 / (row - horizon + 0.5)
      let across: Double = (Double(x) - 256) * distance / 60
      let check = (Int(across.rounded(.down)) + Int((distance * 4).rounded(.down))) % 2
      return check == 0 ? (0.2, 0.55, 0.2) : (0.85, 0.85, 0.7)
    }
    _ = try measuring.open(id: "d", url: url)

    // The far part: the sky and the ground near the horizon, not the ground at your feet.
    let far: JSONValue = ["area": ["type": "frame"], "depth": ["from": 0.6, "to": 1]]
    let share = try coverage("d", far, engine: measuring)
    XCTAssertGreaterThan(share, 0.45)
    XCTAssertLessThan(share, 0.8)
    let lit = try recipe { try $0.setLocal(name: "far", settings: ["mask": far, "adjust": ["exposureEV": 1]]) }
    let plain = try measuring.bitmap(id: "d", recipe: RenderRecipe(), options: RenderOptions(maxEdge: 512), longEdge: 512)
    let result = try measuring.bitmap(id: "d", recipe: lit, options: RenderOptions(maxEdge: 512), longEdge: 512)
    let before = Pixels(data: plain.pixels, width: plain.width, height: plain.height)
    let after = Pixels(data: result.pixels, width: result.width, height: result.height)
    XCTAssertGreaterThan(after.at(256, 20).r, before.at(256, 20).r + 15, "the sky brightens")
    XCTAssertEqual(Double(after.at(256, 370).g), Double(before.at(256, 370).g), accuracy: 3, "the near ground does not")

    // Shown as greys: black nearest, white farthest, the right way up.
    let shown = try measuring.bitmap(id: "d", recipe: RenderRecipe(), options: RenderOptions(maxEdge: 256, depth: true), longEdge: 256)
    let greys = Pixels(data: shown.pixels, width: shown.width, height: shown.height)
    XCTAssertGreaterThan(greys.at(128, 10).g, 220, "the sky is far")
    XCTAssertLessThan(greys.at(128, 185).g, 90, "the ground at the bottom is near")
  }

  func testTappingAnObjectSelectsItAndNothingElse() throws {
    guard let models = models(with: Segmenter.names.decoder) else { throw XCTSkip("the segmentation models have not been fetched (scripts/fetch-models.sh)") }
    let tapping = Engine(useSoftwareRenderer: true, models: models)
    // A dark blue disc on the left and a red square on the right, on light grey.
    let url = try makePNG("things.png", width: 512, height: 384) { x, y in
      let dx = Double(x - 154)
      let dy = Double(y - 192)
      if dx * dx + dy * dy < 60 * 60 { return (0.1, 0.15, 0.45) }
      if (330..<430).contains(x), (142..<242).contains(y) { return (0.8, 0.12, 0.1) }
      return (0.85, 0.85, 0.82)
    }
    _ = try tapping.open(id: "t", url: url)
    let disc = try coverage("t", ["area": ["type": "object", "points": [[0.3, 0.5]]]], engine: tapping)
    let picture: Double = 512 * 384
    let discArea: Double = Double.pi * 60 * 60
    XCTAssertEqual(disc, discArea / picture, accuracy: 0.025, "about the disc")
    let square = try coverage("t", ["area": ["type": "object", "points": [[0.74, 0.5]]]], engine: tapping)
    let squareArea: Double = 100 * 100
    XCTAssertEqual(square, squareArea / picture, accuracy: 0.025, "about the square")

    // Through a local adjustment: the disc changes, the square and the background do not.
    let lit = try recipe { try $0.setLocal(name: "disc", settings: ["mask": ["area": ["type": "object", "points": [[0.3, 0.5]]]], "adjust": ["exposureEV": 1]]) }
    let plain = try tapping.bitmap(id: "t", recipe: RenderRecipe(), options: RenderOptions(maxEdge: 512), longEdge: 512)
    let result = try tapping.bitmap(id: "t", recipe: lit, options: RenderOptions(maxEdge: 512), longEdge: 512)
    let before = Pixels(data: plain.pixels, width: plain.width, height: plain.height)
    let after = Pixels(data: result.pixels, width: result.width, height: result.height)
    XCTAssertGreaterThan(after.at(154, 192).b, before.at(154, 192).b + 20, "the disc brightens")
    XCTAssertEqual(Double(after.at(380, 192).r), Double(before.at(380, 192).r), accuracy: 2, "the square does not")
    XCTAssertEqual(Double(after.at(20, 20).g), Double(before.at(20, 20).g), accuracy: 2, "nor the background")
  }

  func testACollageArrangesItsPiecesAndRearrangesThem() throws {
    _ = try makePNG("red.png", width: 300, height: 400) { _, _ in (0.85, 0.1, 0.1) }
    _ = try makePNG("blue.png", width: 300, height: 400) { _, _ in (0.1, 0.15, 0.85) }
    let manifest = CollageManifest(pieces: [
      CollageManifest.Piece(file: "red.png", name: "Red", width: 300, height: 400),
      CollageManifest.Piece(file: "blue.png", name: "Blue", width: 300, height: 400),
    ])
    let url = directory.appendingPathComponent("made.collage")
    try JSONEncoder().encode(manifest).write(to: url)
    let info = try engine.open(id: "c", url: url)
    XCTAssertEqual(info.pieces?.map(\.name), ["Red", "Blue"])
    XCTAssertEqual(info.width, 4096, "two portraits side by side make a 3:2 canvas")

    func pixels(_ state: EditingState) throws -> Pixels {
      let bitmap = try engine.bitmap(id: "c", recipe: RenderRecipe(state: state, defaults: info.defaults), options: RenderOptions(maxEdge: 300), longEdge: 300)
      XCTAssertEqual(bitmap.width, 300)
      XCTAssertEqual(bitmap.height, 200)
      return Pixels(data: bitmap.pixels, width: bitmap.width, height: bitmap.height)
    }
    var state = EditingState(defaults: info.defaults)
    var shown = try pixels(state)
    XCTAssertGreaterThan(shown.at(75, 100).r, 180, "red on the left")
    XCTAssertGreaterThan(shown.at(225, 100).b, 180, "blue on the right")
    XCTAssertGreaterThan(shown.at(150, 100).g, 220, "a white line between them")
    XCTAssertGreaterThan(shown.at(1, 100).g, 220, "and around them")

    // Swapped, no gap, black: the layout is a setting like any other.
    try state.setLayout(
      ["gap": 0, "background": "#000000", "cells": [["piece": 1, "x": 0, "y": 0, "width": 0.5, "height": 1], ["piece": 0, "x": 0.5, "y": 0, "width": 0.5, "height": 1]]],
      pieces: 2)
    shown = try pixels(state)
    XCTAssertGreaterThan(shown.at(75, 100).b, 180, "blue on the left now")
    XCTAssertGreaterThan(shown.at(225, 100).r, 180, "red on the right")
    XCTAssertLessThan(shown.at(1, 100).g, 60, "no white border")

    // A different shape: the canvas follows it.
    try state.setLayout(["aspect": 1], pieces: 2)
    let square = try engine.bitmap(id: "c", recipe: RenderRecipe(state: state, defaults: info.defaults), options: RenderOptions(maxEdge: 300), longEdge: 300)
    XCTAssertEqual(square.width, square.height)
  }

  func testDisplayPixelsAreSmallAndInDisplayP3() throws {
    _ = try engine.open(id: "p", url: try makePNG("ramp.png", width: 400, height: 300) { x, _ in (Double(x) / 399, 0.5, 0.5) })
    let pixels = try engine.displayPixels(id: "p", recipe: RenderRecipe(), longEdge: 200)
    XCTAssertEqual(pixels.width, 200)
    XCTAssertEqual(pixels.height, 150)
    XCTAssertEqual(pixels.rgba.count, 200 * 150 * 4)
    // A neutral grey is the same in sRGB and Display P3.
    let middle = (75 * 200 + 100) * 4
    XCTAssertEqual(Double(pixels.rgba[middle + 1]), 128, accuracy: 3)
  }

  func testBaseCurveKeepsMidtonesAndRollsOffHighlights() throws {
    let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    func through(_ value: CGFloat) -> Float {
      let color = CIColor(red: value, green: value, blue: value, colorSpace: space)!
      let image = PhotoSession.applyBaseCurve(to: CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1)))
      var pixel = [Float](repeating: 0, count: 4)
      engine.context.render(
        image, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: space)
      return pixel[1]
    }
    XCTAssertEqual(through(0.02), 0.02, accuracy: 0.001, "shadows as measured")
    XCTAssertEqual(through(0.18), 0.18, accuracy: 0.003, "midtones as measured")
    XCTAssertEqual(through(0.6), 0.6, accuracy: 0.005)
    XCTAssertEqual(through(1), Float(ColorPipeline.baseCurve(1)), accuracy: 0.01, "white rolls off")
    XCTAssertGreaterThan(through(4), 0.99, "far brighter than white is white")
    XCTAssertLessThanOrEqual(through(4), 1.001)
  }

  func testBayerRAWGoesThroughTheRAWDecoder() throws {
    try checkRAW(try makeDNG("bayer.dng", linear: false))
  }

  func testLinearRAWLikeProRAWGoesThroughTheRAWDecoder() throws {
    try checkRAW(try makeDNG("linear.dng", linear: true, extended: true))
  }

  /// The camera's frames end in a DNG written back with another raw picture in it
  /// (`DNG.replacingFrame`). Apple's decoder must open that file, and develop it as the samples
  /// and the levels in it say.
  func testARawPictureWrittenBackGoesThroughTheRAWDecoder() throws {
    let original = try makeDNG("frame.dng", extended: true)
    let file = try Data(contentsOf: original)
    let frame = try DNG.frame(of: file)
    XCTAssertEqual(frame.samples.count, 320 * 240)
    XCTAssertEqual(frame.whiteLevel, 65535)
    _ = try engine.open(id: "before", url: original)
    let before = try render("before").1.mean

    // The same picture at half the numbers, with half the white level, is the same picture.
    let halved = frame.samples.map { $0 / 2 }
    let same = directory.appendingPathComponent("frame-same.dng")
    try DNG.replacingFrame(
      of: file, with: RawFrame(width: frame.width, height: frame.height, samples: halved, blackLevels: frame.blackLevels, whiteLevel: 32767, noiseProfile: frame.noiseProfile)
    ).write(to: same)
    let info = try engine.open(id: "same", url: same)
    XCTAssertTrue(info.isRaw)
    XCTAssertEqual(info.width, 320)
    XCTAssertEqual(info.model, "Test Camera", "the rest of the file is still there")
    let after = try render("same").1.mean
    XCTAssertEqual(after.g, before.g, accuracy: 4, "levels scaled with the samples develop the same")
    XCTAssertEqual(after.r, after.g, accuracy: 12)

    // Half the numbers at the old white level is a stop darker.
    let darker = directory.appendingPathComponent("frame-darker.dng")
    try DNG.replacingFrame(
      of: file, with: RawFrame(width: frame.width, height: frame.height, samples: halved, blackLevels: frame.blackLevels, whiteLevel: frame.whiteLevel, noiseProfile: frame.noiseProfile)
    ).write(to: darker)
    _ = try engine.open(id: "darker", url: darker)
    XCTAssertLessThan(try render("darker").1.mean.g, before.g - 15)
  }

  func testAShotsFramesAreMergedTheWayItsSettingsSay() throws {
    // A photo's folder as the camera leaves it: its file, and the frames it was merged from.
    let folder = directory.appendingPathComponent("shot", isDirectory: true)
    let kept = folder.appendingPathComponent(FrameSet.folder, isDirectory: true)
    try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
    let template = try Data(contentsOf: makeDNG("template.dng", extended: true))
    let wall = try DNG.frame(of: template)
    // Three frames of a grey wall, with a lamp further along it in each.
    func place(_ frame: Int) -> (x: Int, y: Int) { (50 + 100 * (frame - 1), 120) }
    let frames: [RawFrame] = (1...3).map { number in
      var frame = wall
      for y in 100..<140 {
        for x in (place(number).x - 20)..<(place(number).x + 20) { frame.samples[y * frame.width + x] = 40000 }
      }
      return frame
    }
    let made = try FrameSet.make(frames: frames, shots: (0..<3).map { FrameSet.Shot(time: 1.0 / 30, iso: 100, after: Double($0)) })
    let original = folder.appendingPathComponent("original.dng")
    try DNG.replacingFrame(of: template, with: made.merged.frame).write(to: original)
    for (index, frame) in frames.enumerated() {
      try DNG.replacingFrame(of: template, with: frame).write(to: kept.appendingPathComponent(FrameSet.fileName(of: index + 1)))
    }
    try JSONEncoder().encode(made.set).write(to: kept.appendingPathComponent(FrameSet.manifest))

    let info = try engine.open(id: "shot", url: original)
    XCTAssertEqual(info.frameSet, made.set)
    XCTAssertEqual(info.defaults.frames, FrameMerge(way: made.set.merge), "its settings start with the camera's own merge")
    XCTAssertEqual(info.json["frames"], 3)
    XCTAssertEqual(info.json["framesKept"], true)

    /// Where the picture has a lamp, of the three places.
    func lamps(_ id: String, _ frames: FrameMerge?) throws -> [Bool] {
      var recipe = RenderRecipe()
      recipe.frames = frames
      let pixels = try render(id, recipe).1
      return (1...3).map { pixels.at(place($0).x, place($0).y).g > 170 }
    }
    let base = made.set.merge.base
    let camera = (1...3).map { $0 == base }
    XCTAssertEqual(try lamps("shot", nil), camera, "the file is the camera's merge: the lamp where its base frame has it")
    XCTAssertEqual(try lamps("shot", FrameMerge(way: made.set.merge)), camera)
    XCTAssertEqual(try lamps("shot", FrameMerge(way: .single(2))), [false, true, false], "one frame alone is that frame")
    let drawn = FrameMerge(way: FrameMerge.Way(base: 1, use: [1, 2, 3], align: .camera, combine: .brightest))
    let removed = FrameMerge(way: FrameMerge.Way(base: 1, use: [1, 2, 3], align: .camera, combine: .median))
    XCTAssertEqual(try lamps("shot", drawn), [true, true, true])
    XCTAssertEqual(try lamps("shot", removed), [false, false, false])
    XCTAssertEqual(try lamps("shot", FrameMerge(way: FrameMerge.Way(base: 3, use: [1, 3]))), [false, false, true], "built on another frame, the moment is that frame's")
    let merges = folder.appendingPathComponent(FrameSet.mergesFolder)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: merges.path).filter { $0.hasSuffix(".dng") }.count, 3, "each merge is kept as a file")

    // A part of the picture merged another way: the lamps drawn on the right, removed on the left.
    let right = try Mask.parse("mask", ["area": ["type": "linear", "from": [0.4, 0.5], "to": [0.3, 0.5]]])
    let mixed = FrameMerge(way: removed.way, areas: [FrameMerge.Area(mask: right, way: drawn.way)])
    XCTAssertEqual(try lamps("shot", mixed), [false, true, true])

    // Onto a finer grid (off in the app for now): drawn at scale 1, the photo keeps its size.
    let finer = FrameMerge(way: FrameMerge.Way(base: 1, use: [1, 2, 3], align: .camera, combine: .median, scale: 2))
    var asked = RenderRecipe()
    asked.frames = finer
    let kept = try render("shot", asked, maxEdge: 0).0
    XCTAssertEqual(kept.width, wall.width)
    XCTAssertEqual(kept.height, wall.height)
    engine.finerGrid = true
    engine.close(id: "shot")
    _ = try engine.open(id: "shot", url: original)

    // Drawn as such: the photo is twice as wide and high, with all three colours at every
    // pixel; another way laid in through a mask is developed to that size.
    func fineLamps(_ frames: FrameMerge) throws -> [Bool] {
      var recipe = RenderRecipe()
      recipe.frames = frames
      let (size, pixels) = try render("shot", recipe, maxEdge: 0)
      XCTAssertEqual(size.width, 2 * wall.width)
      XCTAssertEqual(size.height, 2 * wall.height)
      let factor = Double(pixels.width) / Double(wall.width)
      return (1...3).map { pixels.at(Int(Double(place($0).x) * factor), Int(Double(place($0).y) * factor)).g > 170 }
    }
    XCTAssertEqual(try fineLamps(finer), [false, false, false])
    var plainRecipe = RenderRecipe()
    plainRecipe.frames = removed
    var fineRecipe = RenderRecipe()
    fineRecipe.frames = finer
    XCTAssertEqual(try render("shot", fineRecipe).1.mean.g, try render("shot", plainRecipe).1.mean.g, accuracy: 10, "it develops as the mosaic does")
    XCTAssertEqual(try fineLamps(FrameMerge(way: finer.way, areas: [FrameMerge.Area(mask: right, way: drawn.way)])), [false, true, true])

    // What merging found of each frame: the other two differ from the base where their lamps are.
    var recipe = RenderRecipe()
    recipe.frames = drawn
    let reports = try XCTUnwrap(try engine.frameReports(id: "shot", recipe: recipe))
    XCTAssertEqual(reports.keys.sorted(), [2, 3])
    XCTAssertGreaterThan(reports[2]?.differs ?? 0, 0.005)
    recipe.frames = nil
    XCTAssertNil(try engine.frameReports(id: "shot", recipe: recipe))

    // With the frames gone, a merge already made is still the picture; one that was never made
    // leaves the photo as its file has it.
    engine.close(id: "shot")
    for frame in 1...3 { try FileManager.default.removeItem(at: kept.appendingPathComponent(FrameSet.fileName(of: frame))) }
    var gone = made.set
    gone.kept = false
    try JSONEncoder().encode(gone).write(to: kept.appendingPathComponent(FrameSet.manifest))
    XCTAssertEqual(try engine.open(id: "later", url: original).json["framesKept"], false)
    XCTAssertEqual(try lamps("later", drawn), [true, true, true])
    XCTAssertEqual(try lamps("later", FrameMerge(way: .single(2))), camera)
    XCTAssertEqual(try lamps("later", FrameMerge(way: FrameMerge.Way(base: 2, use: [1, 2, 3], align: .camera, combine: .mean))), camera)
    recipe.frames = FrameMerge(way: .single(2))
    XCTAssertNil(try engine.frameReports(id: "later", recipe: recipe))
  }

  private func checkRAW(_ url: URL) throws {
    let info = try engine.open(id: "raw", url: url)
    XCTAssertTrue(info.isRaw)
    XCTAssertEqual(info.model, "Test Camera")
    XCTAssertGreaterThan(info.defaults.temperature, 2000)

    let (result, neutral) = try render("raw")
    XCTAssertGreaterThan(result.width, 40)
    let base = neutral.mean
    XCTAssertEqual(base.r, base.g, accuracy: 12, "a grey scene with a neutral white balance should stay grey")
    XCTAssertEqual(base.b, base.g, accuracy: 12)

    var brighter = RenderRecipe()
    brighter.exposureEV = 1
    XCTAssertGreaterThan(try render("raw", brighter).1.mean.g, base.g + 15)

    var warmer = RenderRecipe()
    warmer.temperature = info.defaults.temperature + 3000
    warmer.tint = info.defaults.tint
    let warm = try render("raw", warmer).1.mean
    XCTAssertGreaterThan(warm.r - warm.b, base.r - base.b + 5, "a higher temperature should warm a RAW too")

    // Full-resolution export keeps the RAW's size.
    let (full, _) = try render("raw", maxEdge: 0)
    XCTAssertEqual(full.width, info.width)

    // The cached preview development serves renders of other sizes and survives a change of tone settings.
    var toned = brighter
    toned.toneTableSize = 2
    toned.toneTable = floats([0, 0, 0, 1, 1, 1])
    let (small, _) = try render("raw", toned, maxEdge: 100)
    XCTAssertEqual(max(small.width, small.height), 100)
  }
}
