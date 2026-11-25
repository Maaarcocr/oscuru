import Foundation
import XCTest

@testable import OscuruCore

final class BurstMergeTests: XCTestCase {
    static let black = 528.0
    static let white = 4095.0
    /// A high-ISO sensor: a standard deviation of about 60 at mid grey, 28 in the dark.
    static let noise = [8e-4, 6e-5]

    /// A scene that can be sampled anywhere: broad shapes, hard edges and fine texture, so there
    /// is something to line up at every scale and something to lose if frames are blurred together.
    static func scene(_ x: Double, _ y: Double) -> Double {
        var value = 500 + 300 * sin(x / 61) * cos(y / 47)
        if sin(x / 23 + y / 41) + cos(y / 19 - x / 67) > 0.4 { value += 900 }
        if Int(floor(x / 6) + floor(y / 6)) % 5 == 0 { value += 250 }
        value += 120 * sin(x / 2.9) * sin(y / 3.7)
        return value
    }

    /// The gain of each place in the colour pattern: red, green, green, blue.
    static let gains = [0.6, 1.0, 1.0, 0.5]

    /// A frame of `scene` moved by (dx, dy) photosites, with `extra` added over the scene where it
    /// applies, and the sensor's noise unless `clean`.
    static func frame(
        width: Int = 256, height: Int = 192, dx: Double = 0, dy: Double = 0, seed: UInt64 = 0, clean: Bool = false,
        extra: (Double, Double) -> Double = { _, _ in 0 }
    ) -> RawFrame {
        var state = seed &* 2_862_933_555_777_941_757 &+ 3_037_000_493
        func uniform() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Double(state >> 11) + 0.5) / 9_007_199_254_740_992
        }
        let range = white - black
        var samples = [UInt16](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let gain = gains[(y % 2) * 2 + x % 2]
                let signal = gain * (scene(Double(x) + dx, Double(y) + dy) + extra(Double(x), Double(y)))
                var value = black + signal
                if !clean {
                    let deviation = (noise[0] * (signal / range) + noise[1]).squareRoot() * range
                    value += deviation * (-2 * log(uniform())).squareRoot() * cos(2 * Double.pi * uniform())
                }
                samples[y * width + x] = UInt16(max(0, min(white, value.rounded())))
            }
        }
        return RawFrame(width: width, height: height, samples: samples, blackLevels: [black], whiteLevel: white, noiseProfile: noise)
    }

    /// How far a picture is from another, as a root mean square, inside `area` (x, y, width, height).
    static func error(_ a: [Double], _ b: [Double], width: Int, in area: (Int, Int, Int, Int)) -> Double {
        var total = 0.0
        for y in area.1..<(area.1 + area.3) {
            for x in area.0..<(area.0 + area.2) {
                let difference = a[y * width + x] - b[y * width + x]
                total += difference * difference
            }
        }
        return (total / Double(area.2 * area.3)).squareRoot()
    }

    static func values(_ frame: RawFrame, over scale: Double = 1) -> [Double] { frame.samples.map { Double($0) / scale } }

    func testFramesOfAStillSceneAreLinedUpAndTheirNoiseAveragedAway() {
        let clean = Self.frame(clean: true)
        let first = Self.frame(seed: 1)
        var merge = BurstMerge(reference: first)
        // A hand moves the camera a few photosites between frames.
        let moves: [(Double, Double)] = [(2, 4), (-6, 2), (10, -8), (4, 6), (-2, -4), (8, 2), (-4, 10)]
        for (index, move) in moves.enumerated() { merge.add(Self.frame(dx: move.0, dy: move.1, seed: UInt64(index + 2))) }
        XCTAssertEqual(merge.frames, 8)
        let merged = merge.merged()
        XCTAssertEqual(merged.whiteLevel, Self.white * 16, "the levels are scaled up to keep what averaging earned")
        XCTAssertEqual(merged.blackLevels, [Self.black * 16])
        XCTAssertEqual(merged.noiseProfile, Self.noise.map { $0 / 8 })

        // Away from the edges, where a moved frame has nothing to give.
        let inside = (24, 24, 256 - 48, 192 - 48)
        let before = Self.error(Self.values(first), Self.values(clean), width: 256, in: inside)
        let after = Self.error(Self.values(merged, over: 16), Self.values(clean), width: 256, in: inside)
        XCTAssertLessThan(after, before * 0.5, "eight frames leave well under half the noise of one (\(after) against \(before))")
        XCTAssertGreaterThan(after, before * 0.3, "and no less than averaging can give")
    }

    func testWhatMovedBetweenFramesIsKeptFromTheFirstFrameWithoutAGhost() {
        // A bright square that is somewhere else in every frame.
        func square(at corner: (Double, Double)) -> (Double, Double) -> Double {
            { x, y in x >= corner.0 && x < corner.0 + 40 && y >= corner.1 && y < corner.1 + 40 ? 1500 : 0 }
        }
        let clean = Self.frame(clean: true, extra: square(at: (40, 40)))
        var merge = BurstMerge(reference: Self.frame(seed: 1, extra: square(at: (40, 40))))
        let places: [(Double, Double)] = [(150, 40), (150, 110), (40, 120), (100, 80), (190, 130), (96, 20), (20, 80)]
        for (index, place) in places.enumerated() { merge.add(Self.frame(seed: UInt64(index + 2), extra: square(at: place))) }
        let merged = Self.values(merge.merged(), over: 16)
        let expected = Self.values(clean)
        // Nowhere is the picture far from the first frame's scene: not where the square was in
        // another frame (a ghost would be 190 or more above), nor where it is in the first.
        var worst = 0.0
        for y in 24..<168 { for x in 24..<232 { worst = max(worst, abs(merged[y * 256 + x] - expected[y * 256 + x])) } }
        XCTAssertLessThan(worst, 400, "the square shows only where the first frame has it")
        let ghost = Self.error(merged, expected, width: 256, in: (150, 110, 40, 40))
        XCTAssertLessThan(ghost, 60, "where another frame had it, the picture is the first frame's, no noisier than one frame")
    }

    func testDetailThatCannotBeLinedUpIsNotBlurred() {
        // Frames a single photosite apart cannot be laid exactly over each other (a frame only moves
        // by two, to stay behind its own colour filters). Averaging them as they are would smear
        // every edge; the merge keeps the first frame's edges and still averages the flat parts.
        let clean = Self.frame(clean: true)
        let first = Self.frame(seed: 1)
        var merge = BurstMerge(reference: first)
        var plain = Self.values(first)
        let moves: [(Double, Double)] = [(1, 0), (0, 1), (1, 1), (-1, 0), (0, -1), (-1, -1), (1, -1)]
        for (index, move) in moves.enumerated() {
            let frame = Self.frame(dx: move.0, dy: move.1, seed: UInt64(index + 2))
            merge.add(frame)
            // The plain average, for comparison: each frame's sample from the same colour, one pattern over.
            for (index, value) in Self.values(frame).enumerated() { plain[index] += value }
        }
        plain = plain.map { $0 / 8 }
        let merged = Self.values(merge.merged(), over: 16)
        let expected = Self.values(clean)
        let inside = (24, 24, 256 - 48, 192 - 48)
        let single = Self.error(Self.values(first), expected, width: 256, in: inside)
        let robust = Self.error(merged, expected, width: 256, in: inside)
        let smeared = Self.error(plain, expected, width: 256, in: inside)
        XCTAssertLessThan(robust, single * 0.85, "it is still closer to the scene than one frame (\(robust) against \(single))")
        XCTAssertLessThan(robust, smeared * 0.75, "and far closer than frames simply averaged (\(smeared))")
    }

    func testTheSharpestFrameCanBeChosenAsTheReference() {
        let sharp = Self.frame(seed: 1)
        // The same scene with a shake in it: two exposures of it, a few photosites apart, in one.
        let a = Self.frame(clean: true)
        let b = Self.frame(dx: 6, dy: 4, clean: true)
        let shaken = RawFrame(
            width: a.width, height: a.height, samples: zip(a.samples, b.samples).map { UInt16((Int($0) + Int($1)) / 2) }, blackLevels: a.blackLevels,
            whiteLevel: a.whiteLevel, noiseProfile: a.noiseProfile)
        XCTAssertGreaterThan(BurstMerge.sharpness(of: sharp), BurstMerge.sharpness(of: shaken))
    }

    /// With a real iPhone DNG at hand (OSCURU_DNG_SAMPLES, as in DNGTests), a burst is made from
    /// it by moving it and adding its own noise again, merged, and written back as a DNG beside
    /// it for looking at. Says how long a full-size merge takes.
    func testARealFrameMergesAtFullSize() throws {
        guard let folder = ProcessInfo.processInfo.environment["OSCURU_DNG_SAMPLES"] else { throw XCTSkip("no sample files here") }
        let file = try Data(contentsOf: URL(fileURLWithPath: "\(folder)/xs.dng"))
        let original = try DNG.frame(of: file)
        let range = original.whiteLevel - original.blackLevel
        // Much more noise than the file has, as at a high ISO, in its own model's shape.
        let model = [original.noiseProfile[0] * 40, original.noiseProfile[1] * 400]
        func noisy(dx: Int, dy: Int, seed: UInt64) -> RawFrame {
            var state = seed &* 2_862_933_555_777_941_757 &+ 3_037_000_493
            func uniform() -> Double {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return (Double(state >> 11) + 0.5) / 9_007_199_254_740_992
            }
            // Moved by whole patterns, so every sample is still its own colour; past the edge, the edge's own.
            func source(_ position: Int, _ move: Int, _ size: Int) -> Int {
                let moved = position + move
                if moved < 0 { return position % 2 }
                if moved >= size { return size - 2 + position % 2 }
                return moved
            }
            var samples = [UInt16](repeating: 0, count: original.samples.count)
            for y in 0..<original.height {
                let row = source(y, dy, original.height) * original.width
                for x in 0..<original.width {
                    let value = Double(original.samples[row + source(x, dx, original.width)])
                    let signal = max(0, value - original.blackLevel) / range
                    let deviation = (model[0] * signal + model[1]).squareRoot() * range
                    let shaken = value + deviation * (-2 * log(uniform())).squareRoot() * cos(2 * Double.pi * uniform())
                    samples[y * original.width + x] = UInt16(max(0, min(original.whiteLevel, shaken.rounded())))
                }
            }
            return RawFrame(width: original.width, height: original.height, samples: samples, blackLevels: original.blackLevels, whiteLevel: original.whiteLevel, noiseProfile: model)
        }
        let first = noisy(dx: 0, dy: 0, seed: 1)
        try DNG.replacingFrame(of: file, with: first).write(to: URL(fileURLWithPath: "\(folder)/xs.one-frame.dng"))
        var merge = BurstMerge(reference: first)
        let moves = [(4, -2), (-6, 8), (12, 6), (-10, -4), (2, 14), (-14, 2), (8, -12)]
        let started = Date()
        for (index, move) in moves.enumerated() { merge.add(noisy(dx: move.0, dy: move.1, seed: UInt64(index + 2))) }
        let merged = merge.merged()
        print("merged \(merge.frames) frames of \(original.width)×\(original.height) in \(Date().timeIntervalSince(started)) s (the frames' making included)")
        try DNG.replacingFrame(of: file, with: merged).write(to: URL(fileURLWithPath: "\(folder)/xs.merged.dng"))
        XCTAssertEqual(merged.whiteLevel, original.whiteLevel * 16)
    }
}
