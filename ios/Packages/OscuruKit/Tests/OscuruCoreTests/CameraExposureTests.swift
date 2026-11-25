import XCTest

@testable import OscuruCore

final class CameraExposureTests: XCTestCase {
    func testDialsStopAtTheValuesACameraNames() {
        let limits = ExposureLimits(aperture: 1.48...4, apertureStops: [1.48, 1.8, 2.8, 4], time: (1.0 / 45_000)...1, iso: 55...6400)
        XCTAssertEqual(limits.times.last, 1)
        XCTAssertTrue(limits.times.contains(1.0 / 60))
        XCTAssertEqual(limits.times, limits.times.sorted())
        XCTAssertEqual(limits.isos.first, 55, "a range's own end, where no named value is near it")
        XCTAssertEqual(limits.isos.last, 6400)
        XCTAssertFalse(limits.isos.contains(50), "nothing outside the range")
        XCTAssertEqual(limits.apertures, [1.48, 1.6, 1.8, 2, 2.2, 2.5, 2.8, 3.2, 3.5, 4])
        XCTAssertEqual(ExposureLimits(aperture: 1.78...1.78).apertures, [1.78], "a fixed aperture has one")
        XCTAssertTrue(ExposureLimits(aperture: 1.78...1.78).apertureIsFixed)

        XCTAssertEqual(ExposureScale.nearest(1.0 / 65, in: limits.times), 1.0 / 60)
        XCTAssertEqual(ExposureScale.step(1.0 / 60, by: 3, in: limits.times), 1.0 / 30, "three thirds are a stop")
        XCTAssertEqual(ExposureScale.step(1, by: 2, in: limits.times), 1, "and the ends hold")
        XCTAssertTrue(ExposureScale.isWholeTime(1.0 / 125))
        XCTAssertFalse(ExposureScale.isWholeTime(1.0 / 100))
        XCTAssertTrue(ExposureScale.isWholeISO(800))
    }

    func testValuesAreWrittenAsACameraWritesThem() {
        XCTAssertEqual(ExposureScale.timeText(1.0 / 60), "1/60")
        XCTAssertEqual(ExposureScale.timeText(1.0 / 61), "1/60", "close to a named time takes its name")
        XCTAssertEqual(ExposureScale.timeText(1.0 / 45), "1/45", "the camera's own choices between stops stay as they are")
        XCTAssertEqual(ExposureScale.timeText(1.0 / 1130), "1/1100")
        XCTAssertEqual(ExposureScale.timeText(0.5), "0.5″")
        XCTAssertEqual(ExposureScale.timeText(1), "1″")
        XCTAssertEqual(ExposureScale.timeText(2.5), "2.5″")
        XCTAssertEqual(ExposureScale.isoText(100), "100")
        XCTAssertEqual(ExposureScale.isoText(55), "55")
        XCTAssertEqual(ExposureScale.isoText(2260), "2300")
        XCTAssertEqual(ExposureScale.apertureText(1.78), "1.8")
        XCTAssertEqual(ExposureScale.apertureText(4), "4")
        XCTAssertEqual(ExposureScale.stopsText(0.667), "+0.7")
        XCTAssertEqual(ExposureScale.stopsText(-1.333), "−1.3")
        XCTAssertEqual(ExposureScale.stopsText(0.02), "±0")
    }

    func testSettingsFitTheLensInUse() {
        let main = ExposureLimits(aperture: 1.48...4, time: (1.0 / 8000)...1, iso: 50...6400)
        let tele = ExposureLimits(aperture: 2.8...2.8, time: (1.0 / 8000)...0.5, iso: 32...3200)
        let set = ExposureSettings(aperture: 2, time: 1, iso: 6400, bias: -1)
        XCTAssertEqual(set.clamped(to: main), set)
        XCTAssertEqual(set.clamped(to: tele), ExposureSettings(aperture: nil, time: 0.5, iso: 3200, bias: -1), "a fixed aperture is not set")
        XCTAssertTrue(ExposureSettings().isAutomatic)
        XCTAssertFalse(ExposureSettings(time: 0.01, iso: 100).isManual(with: main), "the aperture is still the camera's")
        XCTAssertTrue(ExposureSettings(time: 0.01, iso: 100).isManual(with: tele))
    }

    func testAFrameIsMeasuredForItsTonesAndItsBlownParts() {
        // A dark frame with a lit square: 320 by 240, the square a sixth of the way in.
        let width = 320, height = 240
        var luma = [UInt8](repeating: 20, count: width * height)
        for y in 60..<120 { for x in 80..<160 { luma[y * width + x] = 255 } }
        let chroma = [UInt8](repeating: 128, count: width * height / 2)
        let stats = luma.withUnsafeBytes { lumaBytes in
            chroma.withUnsafeBytes { chromaBytes in
                FrameStatistics.measure(
                    luma: lumaBytes.baseAddress!, lumaRowBytes: width, chroma: chromaBytes.baseAddress!, chromaRowBytes: width, width: width,
                    height: height, fullRange: true)
            }
        }
        XCTAssertEqual(stats.width, 160)
        XCTAssertEqual(stats.height, 120)
        XCTAssertEqual(stats.blownShare, 1.0 / 16, accuracy: 0.005)
        XCTAssertEqual(stats.blown[40 * 160 + 50], 255, "inside the square")
        XCTAssertEqual(stats.blown[10 * 160 + 10], 0)
        XCTAssertEqual(Double(stats.histogram.reduce(0, +)), 1, accuracy: 1e-4)
        XCTAssertGreaterThan(stats.histogram[3], 0.9, "most of it is dark")
        XCTAssertEqual(Double(stats.histogram[FrameStatistics.bins - 1]), 1.0 / 16, accuracy: 0.005)

        // A saturated red light is blown though it is not bright: the red channel has nothing left.
        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        for index in 0..<(64 * 64) { pixels[index * 4] = 255; pixels[index * 4 + 1] = 40; pixels[index * 4 + 2] = 40 }
        let red = pixels.withUnsafeBytes { FrameStatistics.measure(rgba: $0.baseAddress!, rowBytes: 64 * 4, width: 64, height: 64) }
        XCTAssertEqual(red.blownShare, 1)
        XCTAssertEqual(red.histogram[FrameStatistics.bins - 1], 0)
    }
}
