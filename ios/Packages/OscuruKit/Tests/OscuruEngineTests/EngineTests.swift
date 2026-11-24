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
    let size = try engine.export(id: "a", recipe: recipe, format: .jpeg, to: target)
    XCTAssertEqual(size.width, 200)
    XCTAssertEqual(size.height, 400)
    let written = try XCTUnwrap(CGImageSourceCreateWithURL(target as CFURL, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(written, 0, nil))
    XCTAssertEqual(image.width, 200)
    XCTAssertEqual(image.height, 400)
    // The original is only ever read.
    XCTAssertEqual(try Data(contentsOf: url), original)
  }

  func testHEICExport() throws {
    let url = try makePNG("plain.png", width: 64, height: 64, paint: grey(0.5))
    _ = try engine.open(id: "a", url: url)
    let target = directory.appendingPathComponent("export.heic")
    do {
      _ = try engine.export(id: "a", recipe: RenderRecipe(), format: .heic, to: target)
      XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    } catch {
      throw XCTSkip("No HEVC encoder on this machine: \(error)")
    }
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

    // A soft gradient across a hard edge in the photo becomes a sharper step at that edge.
    let photo = CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 300))
      .composited(over: CIImage(color: CIColor(red: 0.9, green: 0.9, blue: 0.9)).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300)))
    let gradient = try Mask.parse("mask", ["area": ["type": "linear", "from": [0.55, 0.5], "to": [0.45, 0.5]]])
    var refinedMask = gradient
    refinedMask.refine = 0.6
    func value(_ mask: Mask, x: Int) -> Double {
      let image = Effects.mask(mask, over: photo, original: { photo }, found: { _ in nil })
      var pixel = [UInt8](repeating: 0, count: 4)
      engine.context.render(image, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: x, y: 150, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
      return Double(pixel[0]) / 255
    }
    XCTAssertLessThan(value(refinedMask, x: 194), value(gradient, x: 194) - 0.08, "darker just left of the photo's edge")
    XCTAssertGreaterThan(value(refinedMask, x: 206), value(gradient, x: 206) + 0.08, "brighter just right of it")
  }

  /// The segmentation models, when they have been fetched (scripts/fetch-models.sh).
  private func segmentationModels() -> URL? {
    let ios = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    for folder in ["Models", "ModelSources"] {
      let url = ios.appendingPathComponent(folder)
      if FileManager.default.fileExists(atPath: url.appendingPathComponent("\(Segmenter.names.decoder).mlmodelc").path)
        || FileManager.default.fileExists(atPath: url.appendingPathComponent("\(Segmenter.names.decoder).mlpackage").path)
      {
        return url
      }
    }
    return nil
  }

  func testTappingAnObjectSelectsItAndNothingElse() throws {
    guard let models = segmentationModels() else { throw XCTSkip("the segmentation models have not been fetched (scripts/fetch-models.sh)") }
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
