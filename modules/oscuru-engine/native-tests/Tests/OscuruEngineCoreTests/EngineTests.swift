import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import OscuruEngineCore

/// These tests pin down what the TypeScript side assumes about Core Image: table layouts, colour
/// spaces, directions of rotation and white balance, and that a RAW file goes through the RAW decoder.
final class EngineTests: XCTestCase {
  private var directory: URL!
  private var engine: Engine!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("oscuru-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    engine = Engine(outputDirectory: directory.appendingPathComponent("out"), useSoftwareRenderer: true)
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

  private func render(_ id: String, _ recipe: RenderRecipe = RenderRecipe(), maxEdge: Double = 512, fullFrame: Bool = false) throws -> (RenderResult, Pixels) {
    var options = RenderOptions()
    options.maxEdge = maxEdge
    options.statsEdge = 512
    options.fullFrame = fullFrame
    let result = try engine.render(id: id, recipe: recipe, options: options)
    return (result, Pixels(data: result.statsPixels, width: result.statsWidth, height: result.statsHeight))
  }

  private func floats(_ values: [Float]) -> Data {
    values.withUnsafeBufferPointer { Data(buffer: $0) }
  }

  // MARK: Opening

  func testOpenReportsSizeAndDefaults() throws {
    let url = try makePNG("plain.png", width: 60, height: 40, paint: grey(0.5))
    let metadata = try engine.open(id: "a", url: url)
    XCTAssertEqual(metadata["width"] as? Int, 60)
    XCTAssertEqual(metadata["height"] as? Int, 40)
    XCTAssertEqual(metadata["isRaw"] as? Bool, false)
    let defaults = metadata["defaults"] as? [String: Double]
    XCTAssertEqual(defaults?["temperature"], 6500)
    XCTAssertEqual(defaults?["noiseReduction"], 0)
  }

  func testOpeningSomethingThatIsNotAnImageFails() throws {
    let url = directory.appendingPathComponent("notes.txt")
    try Data("hello".utf8).write(to: url)
    XCTAssertThrowsError(try engine.open(id: "a", url: url))
  }

  func testRenderingAnUnknownSessionFails() {
    XCTAssertThrowsError(try engine.render(id: "nope", recipe: RenderRecipe(), options: RenderOptions()))
  }

  // MARK: Output

  func testIdentityRecipeKeepsThePhoto() throws {
    let url = try makePNG("ramp.png", width: 64, height: 32) { x, _ in
      let value = Double(x) / 63
      return (value, value * 0.5, 1 - value)
    }
    _ = try engine.open(id: "a", url: url)
    let (result, pixels) = try render("a")
    XCTAssertEqual(result.width, 64)
    XCTAssertEqual(result.height, 32)
    XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.path))
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

  func testEachSlotKeepsOneFile() throws {
    let url = try makePNG("plain.png", width: 16, height: 16, paint: grey(0.5))
    _ = try engine.open(id: "a", url: url)
    let (first, _) = try render("a")
    let (second, _) = try render("a")
    XCTAssertNotEqual(first.url, second.url)
    XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
    engine.close(id: "a")
    XCTAssertFalse(FileManager.default.fileExists(atPath: second.url.path))
  }

  func testPreviewsAreScaledAndExportsAreNot() throws {
    let url = try makePNG("big.png", width: 400, height: 200, paint: grey(0.4))
    _ = try engine.open(id: "a", url: url)
    let (preview, _) = try render("a", maxEdge: 100)
    XCTAssertEqual(preview.width, 100)
    XCTAssertEqual(preview.height, 50)
    let (full, _) = try render("a", maxEdge: 0)
    XCTAssertEqual(full.width, 400)
    XCTAssertEqual(full.height, 200)
  }

  func testHEICExport() throws {
    let url = try makePNG("plain.png", width: 64, height: 64, paint: grey(0.5))
    _ = try engine.open(id: "a", url: url)
    var options = RenderOptions()
    options.format = "heic"
    options.slot = "export"
    do {
      let result = try engine.render(id: "a", recipe: RenderRecipe(), options: options)
      XCTAssertEqual(result.url.pathExtension, "heic")
      XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.path))
    } catch {
      throw XCTSkip("No HEVC encoder on this machine: \(error)")
    }
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
    // Red inverted, green untouched, blue forced to zero. Core Image looks entries up without
    // interpolating between them, so the app sends a fine table (TONE_TABLE_SIZE in color.ts).
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
    XCTAssertEqual(pixel.r, 191, accuracy: 2)
    XCTAssertEqual(pixel.g, 64, accuracy: 2)
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
    XCTAssertEqual(result.width, 40)
    XCTAssertEqual(result.height, 80)
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
    XCTAssertEqual(result.width, 40)
    XCTAssertEqual(result.height, 20)
    XCTAssertGreaterThan(pixels.at(2, 2).b, 200)

    let (whole, _) = try render("a", cropped, fullFrame: true)
    XCTAssertEqual(whole.width, 80)
    XCTAssertEqual(whole.height, 40)
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
  private func makeDNG(_ name: String, width: Int = 64, height: Int = 48, linear: Bool = false, extended: Bool = false, level: UInt16 = 11796) throws -> URL {
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

  /// Prints what Apple's RAW decoder makes of each synthetic DNG variant, and returns the first it can develop.
  private func developableDNG() throws -> URL? {
    var chosen: URL?
    for (width, height) in [(64, 48), (320, 240)] {
      for linear in [false, true] {
        for extended in [false, true] {
          let name = "dng-\(width)-\(linear ? "linear" : "bayer")-\(extended ? "extended" : "minimal").dng"
          let url = try makeDNG(name, width: width, height: height, linear: linear, extended: extended)
          let source = CGImageSourceCreateWithURL(url as CFURL, nil)
          let type = source.flatMap { CGImageSourceGetType($0) as String? } ?? "none"
          let status = source.map { CGImageSourceGetStatus($0).rawValue } ?? -99
          let filter = CIRAWFilter(imageURL: url)
          let extent = filter?.outputImage?.extent
          print("DNG \(name): type \(type) status \(status) filter \(filter != nil) nativeSize \(String(describing: filter?.nativeSize)) extent \(String(describing: extent)) temperature \(String(describing: filter?.neutralTemperature))")
          if chosen == nil, let extent = extent, extent.width >= 1, extent.height >= 1, !extent.isInfinite {
            chosen = url
          }
        }
      }
    }
    return chosen
  }

  func testRAWFilesGoThroughTheRAWDecoder() throws {
    let url = try XCTUnwrap(try developableDNG(), "Apple's RAW decoder developed none of the synthetic DNGs")
    print("Using \(url.lastPathComponent)")
    let metadata = try engine.open(id: "raw", url: url)
    XCTAssertEqual(metadata["isRaw"] as? Bool, true)
    XCTAssertEqual(metadata["model"] as? String, "Test Camera")
    let asShot = metadata["asShot"] as? [String: Double]
    XCTAssertNotNil(asShot)
    XCTAssertGreaterThan(asShot?["temperature"] ?? 0, 2000)

    let (result, neutral) = try render("raw")
    XCTAssertGreaterThan(result.width, 40)
    let base = neutral.mean
    XCTAssertEqual(base.r, base.g, accuracy: 12, "a grey scene with a neutral white balance should stay grey")
    XCTAssertEqual(base.b, base.g, accuracy: 12)

    var brighter = RenderRecipe()
    brighter.exposureEV = 1
    XCTAssertGreaterThan(try render("raw", brighter).1.mean.g, base.g + 15)

    var warmer = RenderRecipe()
    warmer.temperature = (asShot?["temperature"] ?? 6500) + 3000
    warmer.tint = asShot?["tint"] ?? 0
    let warm = try render("raw", warmer).1.mean
    XCTAssertGreaterThan(warm.r - warm.b, base.r - base.b + 5, "a higher temperature should warm a RAW too")

    // Full-resolution export keeps the RAW's size.
    let (full, _) = try render("raw", maxEdge: 0)
    XCTAssertEqual(full.width, metadata["width"] as? Int)
  }
}
