import Foundation
import XCTest

@testable import OscuruCore

final class ImageAnalysisTests: XCTestCase {
    private typealias Pixel = (UInt8, UInt8, UInt8)

    /// An opaque RGBA8 bitmap, row-major from the top row.
    private func bitmap(_ width: Int, _ height: Int, _ paint: (_ x: Int, _ y: Int) -> Pixel) -> Data {
        var pixels = Data(capacity: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = paint(x, y)
                pixels.append(contentsOf: [r, g, b, 255])
            }
        }
        return pixels
    }

    private func analyze(_ width: Int, _ height: Int, _ paint: (_ x: Int, _ y: Int) -> Pixel) throws -> ImageAnalysis {
        try XCTUnwrap(ImageAnalysis(pixels: bitmap(width, height, paint), width: width, height: height))
    }

    private func number(_ analysis: ImageAnalysis, _ path: String...) throws -> Double {
        var value: JSONValue? = analysis.statistics
        for key in path { value = value?[key] }
        return try XCTUnwrap(value?.doubleValue, "statistics has no number at \(path.joined(separator: "."))")
    }

    // MARK: Flat grey

    func testMeasuresAFlatGrey() throws {
        let analysis = try analyze(8, 8) { _, _ in (128, 128, 128) }
        let histogram = analysis.histogram
        XCTAssertEqual(histogram.luminance.count, 256)
        XCTAssertEqual(histogram.luminance[128], 1)
        XCTAssertEqual(histogram.luminance.reduce(0, +), 1, accuracy: 5e-6)
        XCTAssertEqual(histogram.red[128], 1)
        XCTAssertEqual(histogram.green[128], 1)
        XCTAssertEqual(histogram.blue[128], 1)
        XCTAssertEqual(histogram.highlightClipping, 0)
        XCTAssertEqual(histogram.shadowClipping, 0)

        XCTAssertEqual(try number(analysis, "width"), 8)
        XCTAssertEqual(try number(analysis, "height"), 8)
        XCTAssertEqual(try number(analysis, "meanLuminance"), 0.502, accuracy: 0.0005)
        XCTAssertEqual(analysis.meanLuminance, try number(analysis, "meanLuminance"))
        XCTAssertEqual(try number(analysis, "medianLuminance"), 0.502, accuracy: 0.0005)
        XCTAssertEqual(try number(analysis, "contrast"), 0)
        XCTAssertEqual(try number(analysis, "dynamicRange"), 0)
        XCTAssertEqual(try number(analysis, "averageSaturation"), 0)
        XCTAssertEqual(try number(analysis, "highlightClipping"), 0)
        XCTAssertEqual(try number(analysis, "shadowClipping"), 0)
        XCTAssertEqual(analysis.statistics["meanRGB"], [0.502, 0.502, 0.502])
        XCTAssertEqual(analysis.statistics["colorCast"], ["red": 0, "green": 0, "blue": 0])
        XCTAssertEqual(analysis.statistics["clippedChannels"], ["red": 0, "green": 0, "blue": 0])
        XCTAssertEqual(analysis.statistics["zones"], [[0.502, 0.502, 0.502], [0.502, 0.502, 0.502], [0.502, 0.502, 0.502]])
        XCTAssertEqual(analysis.colorShare("neutral"), 1)
        for color in Specs.colorRanges { XCTAssertEqual(analysis.colorShare(color), 0, color) }
        for name in ["p1", "p5", "p25", "p50", "p75", "p95", "p99"] {
            XCTAssertEqual(try number(analysis, "percentiles", name), 0.502, accuracy: 0.0005, name)
        }
    }

    func testStatisticsHaveEveryFieldTheAPIDocuments() throws {
        let analysis = try analyze(4, 4) { x, y in (UInt8(x * 60), UInt8(y * 60), 90) }
        XCTAssertEqual(
            Set(analysis.statistics.objectValue?.keys.map { $0 } ?? []),
            [
                "width", "height", "meanLuminance", "medianLuminance", "percentiles", "contrast", "dynamicRange", "averageSaturation", "meanRGB",
                "colorCast", "highlightClipping", "shadowClipping", "clippedChannels", "zones", "colorDistribution",
            ])
        XCTAssertEqual(Set(analysis.statistics["colorDistribution"]?.objectValue?.keys.map { $0 } ?? []), Set(Specs.colorRanges + ["neutral"]))
        XCTAssertEqual(Set(analysis.statistics["percentiles"]?.objectValue?.keys.map { $0 } ?? []), ["p1", "p5", "p25", "p50", "p75", "p95", "p99"])
    }

    func testHistogramAsJSON() throws {
        let analysis = try analyze(2, 2) { x, _ in x == 0 ? (0, 0, 0) : (255, 255, 255) }
        let json = analysis.histogram.json
        XCTAssertEqual(json["bins"], 256)
        for channel in ["luminance", "red", "green", "blue"] {
            let bins = try XCTUnwrap(json[channel]?.arrayValue, channel)
            XCTAssertEqual(bins.count, 256, channel)
            XCTAssertEqual(bins.first, 0.5, channel)
            XCTAssertEqual(bins.last, 0.5, channel)
        }
        XCTAssertEqual(json["highlightClipping"], 0.5)
        XCTAssertEqual(json["shadowClipping"], 0.5)
    }

    // MARK: Clipping, zones, casts, colours

    func testReportsClippingZonesCastsAndColourRanges() throws {
        // Top third white (a clipped sky), middle a saturated blue, bottom black.
        let analysis = try analyze(9, 9) { _, y in y < 3 ? (255, 255, 255) : y < 6 ? (20, 40, 220) : (0, 0, 0) }
        XCTAssertEqual(analysis.histogram.highlightClipping, 1.0 / 3, accuracy: 0.0005)
        XCTAssertEqual(analysis.histogram.shadowClipping, 1.0 / 3, accuracy: 0.0005)
        XCTAssertEqual(try number(analysis, "highlightClipping"), analysis.histogram.highlightClipping)
        XCTAssertEqual(try number(analysis, "shadowClipping"), analysis.histogram.shadowClipping)

        let zones = try XCTUnwrap(analysis.statistics["zones"]?.arrayValue)
        XCTAssertEqual(zones.count, 3)
        XCTAssertEqual(zones[0], [1, 1, 1])
        XCTAssertEqual(zones[2], [0, 0, 0])
        XCTAssertEqual(zones[1].arrayValue?[0].doubleValue ?? 0, (0.2126 * 20 + 0.7152 * 40 + 0.0722 * 220) / 255, accuracy: 0.0005)

        XCTAssertEqual(analysis.colorShare("blue"), 1.0 / 3, accuracy: 0.0005)
        XCTAssertEqual(analysis.colorShare("neutral"), 2.0 / 3, accuracy: 0.0005)
        XCTAssertGreaterThan(try number(analysis, "colorCast", "blue"), try number(analysis, "colorCast", "red"))
        XCTAssertEqual(try number(analysis, "percentiles", "p1"), 0)
        XCTAssertEqual(try number(analysis, "percentiles", "p99"), 1)
        XCTAssertEqual(try number(analysis, "dynamicRange"), 1)
        XCTAssertEqual(try number(analysis, "clippedChannels", "red"), 1.0 / 3, accuracy: 0.0005)
        XCTAssertGreaterThan(try number(analysis, "contrast"), 0.3)
    }

    func testZonesAreRowsFromTheTopEachLeftToRight() throws {
        // Brightness rises by column and by row, so every zone has its own value.
        let analysis = try analyze(6, 6) { x, y in
            let level = UInt8((y / 2) * 60 + (x / 2) * 20)
            return (level, level, level)
        }
        let zones = try XCTUnwrap(analysis.statistics["zones"]?.arrayValue)
        for row in 0..<3 {
            for column in 0..<3 {
                let expected = Double(row * 60 + column * 20) / 255
                XCTAssertEqual(zones[row].arrayValue?[column].doubleValue ?? -1, expected, accuracy: 0.0006, "zone \(row),\(column)")
            }
        }
    }

    func testCountsAHighlightAsClippedWhenAnyChannelIsAtTheTop() throws {
        // Left half: only red is clipped. Right half: a mid grey.
        let analysis = try analyze(4, 2) { x, _ in x < 2 ? (255, 100, 100) : (120, 120, 120) }
        XCTAssertEqual(analysis.histogram.highlightClipping, 0.5)
        XCTAssertEqual(analysis.statistics["clippedChannels"], ["red": 0.5, "green": 0, "blue": 0])
        XCTAssertEqual(analysis.histogram.shadowClipping, 0)
    }

    func testCountsAShadowAsClippedOnlyWhenEveryChannelIsAtTheBottom() throws {
        let analysis = try analyze(4, 1) { x, _ in [(0, 0, 0), (2, 2, 2), (3, 0, 0), (0, 0, 40)][x] }
        XCTAssertEqual(analysis.histogram.shadowClipping, 0.5)
    }

    func testClippingStartsJustBelowTheVeryTop() throws {
        let analysis = try analyze(4, 1) { x, _ in [(252, 252, 252), (253, 253, 253), (254, 254, 254), (255, 255, 255)][x] }
        XCTAssertEqual(analysis.histogram.highlightClipping, 0.75)
    }

    func testMeasuresAWarmCast() throws {
        let analysis = try analyze(4, 4) { _, _ in (200, 150, 100) }
        XCTAssertGreaterThan(try number(analysis, "colorCast", "red"), 0.15)
        XCTAssertEqual(try number(analysis, "colorCast", "green"), 0, accuracy: 0.0001)
        XCTAssertLessThan(try number(analysis, "colorCast", "blue"), -0.15)
        XCTAssertEqual(analysis.statistics["meanRGB"], [0.7843, 0.5882, 0.3922])
        XCTAssertEqual(try number(analysis, "averageSaturation"), 0.5)
        XCTAssertEqual(analysis.colorShare("orange"), 1)
        XCTAssertEqual(analysis.colorShare("neutral"), 0)
    }

    func testSortsClearColoursIntoTheNearestRange() throws {
        // One pure colour per column, at the centre of each range, in the order of Specs.colorRanges.
        let colours: [Pixel] = [(255, 0, 0), (255, 128, 0), (255, 255, 0), (0, 255, 0), (0, 255, 255), (0, 0, 255), (128, 0, 255), (255, 0, 255)]
        let analysis = try analyze(8, 2) { x, _ in colours[x] }
        for color in Specs.colorRanges { XCTAssertEqual(analysis.colorShare(color), 0.125, color) }
        XCTAssertEqual(analysis.colorShare("neutral"), 0)
        XCTAssertEqual(analysis.colorShare("teal"), 0, "an unknown range has no share")
        XCTAssertEqual(try number(analysis, "averageSaturation"), 1)
    }

    func testTreatsMutedAndVeryDarkPixelsAsNeutral() throws {
        // A weak tint, a dark but saturated red, and a clear green.
        let analysis = try analyze(3, 1) { x, _ in [(200, 190, 185), (25, 0, 0), (40, 200, 40)][x] }
        XCTAssertEqual(analysis.colorShare("neutral"), 0.6667, accuracy: 0.0001)
        XCTAssertEqual(analysis.colorShare("green"), 0.3333, accuracy: 0.0001)
        XCTAssertEqual(analysis.colorShare("red"), 0)
    }

    func testPercentilesFollowTheLuminanceDistribution() throws {
        // A ramp with one pixel at each of the 256 levels.
        let analysis = try analyze(256, 1) { x, _ in (UInt8(x), UInt8(x), UInt8(x)) }
        for value in analysis.histogram.luminance { XCTAssertEqual(value, 1.0 / 256, accuracy: 1e-5) }
        XCTAssertEqual(analysis.histogram.luminance.reduce(0, +), 1, accuracy: 0.001)
        XCTAssertEqual(try number(analysis, "percentiles", "p50"), 127.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(try number(analysis, "medianLuminance"), try number(analysis, "percentiles", "p50"))
        XCTAssertEqual(try number(analysis, "percentiles", "p25"), 63.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(try number(analysis, "percentiles", "p75"), 191.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(try number(analysis, "percentiles", "p1"), 2.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(try number(analysis, "percentiles", "p99"), 253.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(try number(analysis, "dynamicRange"), 251.0 / 255, accuracy: 0.0002)
        XCTAssertEqual(try number(analysis, "meanLuminance"), 0.5, accuracy: 0.0001)
        // The standard deviation of a uniform distribution over 0–1 is 1/√12.
        XCTAssertEqual(try number(analysis, "contrast"), 1 / 12.0.squareRoot(), accuracy: 0.002)
    }

    func testIgnoresTheAlphaChannel() throws {
        let opaque = bitmap(4, 4) { x, y in (UInt8(x * 50), UInt8(y * 50), 77) }
        var transparent = opaque
        for index in stride(from: 3, to: transparent.count, by: 4) { transparent[index] = 0 }
        XCTAssertEqual(ImageAnalysis(pixels: transparent, width: 4, height: 4), ImageAnalysis(pixels: opaque, width: 4, height: 4))
    }

    func testReadsOnlyTheBitmapWhenTheDataIsLonger() throws {
        let exact = bitmap(3, 3) { x, y in (UInt8(x * 80), UInt8(y * 80), 10) }
        let longer = exact + Data(repeating: 255, count: 64)
        XCTAssertEqual(ImageAnalysis(pixels: longer, width: 3, height: 3), ImageAnalysis(pixels: exact, width: 3, height: 3))
    }

    func testMeasuresASliceOfLargerData() throws {
        let exact = bitmap(3, 3) { x, y in (UInt8(x * 80), UInt8(y * 80), 10) }
        let padded = Data(repeating: 7, count: 5) + exact
        let slice = padded[5...]
        XCTAssertEqual(ImageAnalysis(pixels: slice, width: 3, height: 3), ImageAnalysis(pixels: exact, width: 3, height: 3))
    }

    // MARK: Refusals

    func testIsNilForDataThatIsTooShort() {
        XCTAssertNil(ImageAnalysis(pixels: Data(count: 8), width: 4, height: 4))
        XCTAssertNil(ImageAnalysis(pixels: Data(count: 63), width: 4, height: 4))
        XCTAssertNotNil(ImageAnalysis(pixels: Data(count: 64), width: 4, height: 4))
        XCTAssertNil(ImageAnalysis(pixels: Data(), width: 1, height: 1))
    }

    func testIsNilForAnEmptyBitmap() {
        XCTAssertNil(ImageAnalysis(pixels: Data(), width: 0, height: 0))
        XCTAssertNil(ImageAnalysis(pixels: Data(count: 64), width: 0, height: 4))
        XCTAssertNil(ImageAnalysis(pixels: Data(count: 64), width: 4, height: 0))
    }

    func testIsNilForNegativeSizes() {
        XCTAssertNil(ImageAnalysis(pixels: Data(count: 64), width: -4, height: -4))
        XCTAssertNil(ImageAnalysis(pixels: Data(count: 64), width: -4, height: 4))
    }
}
