import Foundation
import XCTest

@testable import OscuruCore

/// The ways of merging that come from lining frames up and combining them differently: onto a
/// finer grid, the sharpest of each place, following one part of the frame.
final class FrameToolsTests: XCTestCase {
    typealias Scene = BurstMergeTests

    /// A scene with nothing sharper than a lens would let through, so that frames moved by a
    /// fraction of a photosite see it moved by just that: broad waves, round spots, fine stripes
    /// (thinner than a colour of the filter pattern can hold on its own) in one part, and a flat patch.
    static func scene(_ x: Double, _ y: Double) -> Double {
        if x >= 200, x < 250, y >= 20, y < 80 { return 900 }
        var value = 1000 + 300 * sin(x / 11 + y / 17) + 250 * cos(x / 7.3 - y / 9.1) + 150 * sin(x / 4.1 + y / 15) * cos(y / 6.3 - x / 23)
        for spot in spots {
            let dx = x - spot.x
            let dy = y - spot.y
            value += spot.light * exp(-(dx * dx + dy * dy) / 18)
        }
        if x > 64, x < 192, y > 48, y < 144 { value += 260 * sin(2 * Double.pi * (x + 0.4 * y) / 3.4) }
        return value
    }

    static let spots: [(x: Double, y: Double, light: Double)] = (0..<60).map { index in
        let at = Double(index)
        return ((at * 37.31).truncatingRemainder(dividingBy: 256), (at * 23.77 + 11.3).truncatingRemainder(dividingBy: 192), index % 2 == 0 ? 500 : -300)
    }

    /// A frame of `scene` moved by (dx, dy) photosites, with the sensor's noise.
    static func frame(dx: Double, dy: Double, seed: UInt64) -> RawFrame {
        Scene.frame(seed: seed, extra: { x, y in Self.scene(x + dx, y + dy) - Scene.scene(x, y) })
    }

    /// One colour of a frame at a place between its photosites, from its own photosites of that
    /// colour: what one frame alone can say of it.
    static func interpolated(_ frame: RawFrame, colour: Int, _ x: Double, _ y: Double) -> Double {
        let places = (0..<4).filter { frame.cfa[$0] == colour }
        var total = 0.0
        for place in places {
            let ox = Double(place % 2)
            let oy = Double(place / 2)
            // On that colour's own grid (every other photosite), between its four nearest.
            let gx = (x - ox) / 2
            let gy = (y - oy) / 2
            let x0 = Int(gx.rounded(.down))
            let y0 = Int(gy.rounded(.down))
            let a = gx - Double(x0)
            let b = gy - Double(y0)
            func at(_ i: Int, _ j: Int) -> Double {
                let px = min(max(2 * i + Int(ox), 0), frame.width - 1)
                let py = min(max(2 * j + Int(oy), 0), frame.height - 1)
                return Double(frame.samples[py * frame.width + px]) - frame.blackLevel
            }
            total += (at(x0, y0) * (1 - a) + at(x0 + 1, y0) * a) * (1 - b) + (at(x0, y0 + 1) * (1 - a) + at(x0 + 1, y0 + 1) * a) * b
        }
        return total / Double(places.count)
    }

    func testFramesMergedOntoAFinerGridHoldMoreDetailThanOneFrame() throws {
        // Eight frames from a hand that moved by fractions of a photosite between them.
        let moves: [(Double, Double)] = [(0, 0), (0.5, 0.25), (-0.75, 0.5), (1.25, -0.5), (0.25, 1.0), (-1.5, -1.25), (0.75, 1.5), (-0.25, -0.75)]
        let frames = moves.enumerated().map { index, move in Self.frame(dx: move.0, dy: move.1, seed: UInt64(index + 1)) }
        let result = try FrameMerging.merge(FrameMerge.Way(base: 1, use: Array(1...8), scale: 2), light: [Double](repeating: 1, count: 8)) { frames[$0 - 1] }
        guard case .rgb(let picture, let brightening) = result.merged else { return XCTFail("a finer grid gives all three colours") }
        XCTAssertEqual(picture.width, 512)
        XCTAssertEqual(picture.height, 384)
        XCTAssertEqual(brightening, 0)
        XCTAssertEqual(result.reports.keys.sorted(), Array(2...8))
        let scale = picture.blackLevel / Scene.black

        // Against the scene itself, in an area of the picture (in pixels of the finer grid): the
        // merge, and one frame's colours spread between its photosites.
        func errors(x: Range<Int>, y: Range<Int>) -> (merged: Double, single: Double) {
            var merged = 0.0
            var single = 0.0
            for oy in y {
                for ox in x {
                    let sx = (Double(ox) + 0.5) / 2 - 0.5
                    let sy = (Double(oy) + 0.5) / 2 - 0.5
                    let light = Self.scene(sx, sy)
                    let at = (oy * picture.width + ox) * 3
                    for colour in 0..<3 {
                        let wanted = light * Scene.gains[[0, 1, 3][colour]]
                        let made = Double(picture.samples[at + colour]) / scale - Scene.black
                        let one = Self.interpolated(frames[0], colour: colour, sx, sy)
                        merged += (made - wanted) * (made - wanted)
                        single += (one - wanted) * (one - wanted)
                    }
                }
            }
            let count = Double(x.count * y.count * 3)
            return ((merged / count).squareRoot(), (single / count).squareRoot())
        }
        let stripes = errors(x: 140..<370, y: 110..<270)
        XCTAssertLessThan(stripes.merged, stripes.single * 0.6, "in the fine stripes, the merge is far closer to the scene (\(stripes.merged)) than one frame can be (\(stripes.single))")
        let flat = errors(x: 410..<490, y: 50..<150)
        XCTAssertLessThan(flat.merged, flat.single * 0.8, "where it is flat, it is less noisy (\(flat.merged) against \(flat.single))")
    }

    func testTheSharpestOfEachPlaceMakesOnePictureSharpThroughout() throws {
        // Two frames focused differently: the first sharp on the left, the second on the right.
        func soft(_ x: Double, _ y: Double) -> Double {
            var total = 0.0
            for j in -3...3 { for i in -3...3 { total += Scene.scene(x + Double(i), y + Double(j)) } }
            return total / 49 - Scene.scene(x, y)
        }
        let left = Scene.frame(seed: 1, extra: { x, y in x < 128 ? 0 : soft(x, y) })
        let right = Scene.frame(seed: 2, extra: { x, y in x < 128 ? soft(x, y) : 0 })
        let clean = Scene.frame(clean: true).samples.map { Double($0) - Scene.black }
        let result = try FrameMerging.merge(FrameMerge.Way(base: 1, use: [1, 2], align: .none, combine: .sharpest), light: [1, 1]) { [left, right][$0 - 1] }
        let values = FrameMergingTests.light(result.merged, base: left)
        let leftHalf = (16, 16, 96, 160)
        let rightHalf = (144, 16, 96, 160)
        let soft1 = Scene.error(left.samples.map { Double($0) - Scene.black }, clean, width: 256, in: rightHalf)
        let soft2 = Scene.error(right.samples.map { Double($0) - Scene.black }, clean, width: 256, in: leftHalf)
        XCTAssertLessThan(Scene.error(values, clean, width: 256, in: leftHalf), soft2 * 0.6, "the left from the frame sharp there")
        XCTAssertLessThan(Scene.error(values, clean, width: 256, in: rightHalf), soft1 * 0.6, "the right from the other")
    }

    func testTheCameraMergesAFocusBracketSharpThroughout() throws {
        // Focused near (the left is near), then far, with the hand moving a little between them.
        func soft(_ x: Double, _ y: Double) -> Double {
            var total = 0.0
            for j in -3...3 { for i in -3...3 { total += Scene.scene(x + Double(i), y + Double(j)) } }
            return total / 49 - Scene.scene(x, y)
        }
        let near = Scene.frame(seed: 1, extra: { x, y in x < 128 ? 0 : soft(x, y) })
        let far = Scene.frame(dx: 2, dy: -2, seed: 2, extra: { x, y in x + 2 < 128 ? soft(x + 2, y - 2) : 0 })
        let shots = [FrameSet.Shot(time: 0.01, iso: 100, after: 0, focus: 0.3), FrameSet.Shot(time: 0.01, iso: 100, after: 0.2, focus: 1)]
        let made = try FrameSet.make(frames: [near, far], shots: shots)
        XCTAssertEqual(made.set.merge.combine, .sharpest)
        XCTAssertEqual(made.set.merge.base, 1, "on the frame focused where the person focused")
        XCTAssertEqual(made.set.frames.map(\.focus), [0.3, 1])
        XCTAssertEqual(made.set.json(with: made.set.merge).arrayValue?.first?.objectValue?["focus"], 0.3)
        let values = FrameMergingTests.light(.mosaic(made.merged), base: near)
        let clean = Scene.frame(clean: true).samples.map { Double($0) - Scene.black }
        let leftHalf = (16, 16, 96, 160)
        let rightHalf = (144, 16, 96, 160)
        let blurredRight = Scene.error(near.samples.map { Double($0) - Scene.black }, clean, width: 256, in: rightHalf)
        XCTAssertLessThan(Scene.error(values, clean, width: 256, in: rightHalf), blurredRight * 0.6, "the far side from the frame focused far")
        XCTAssertLessThan(Scene.error(values, clean, width: 256, in: leftHalf), blurredRight * 0.6)

        // Frames focused alike are merged as ever.
        let plain = try FrameSet.make(frames: [near, near], shots: [FrameSet.Shot(time: 0.01, iso: 100, after: 0), FrameSet.Shot(time: 0.01, iso: 100, after: 0.1)])
        XCTAssertEqual(plain.set.merge.combine, .robust)
        XCTAssertNil(plain.set.json(with: plain.set.merge).arrayValue?.first?.objectValue?["focus"])
    }

    func testFollowingOnePartOfTheFrameKeepsItSharpAndBlursTheRest() throws {
        // A textured thing crossing a still scene, two photosites further in each frame: the camera
        // followed it, as in a panning shot (here the scene moves under the camera instead).
        func thing(_ index: Int) -> (Double, Double) -> Double {
            { x, y in
                let left = 90.0 + 2 * Double(index)
                guard x >= left, x < left + 70, y >= 60, y < 130 else { return 0 }
                return 700 + 300 * sin((x - left) / 2.3) * cos((y - 60) / 3.1) - Scene.scene(x, y)
            }
        }
        let frames = (0..<5).map { index in Scene.frame(seed: UInt64(index + 1), extra: thing(index)) }
        let light = [Double](repeating: 1, count: 5)
        // The thing in the base frame, as a part of the frame from its top-left corner.
        let on = FrameMerge.Rect(x: 95.0 / 256, y: 65.0 / 192, width: 60.0 / 256, height: 60.0 / 192)
        let followed = try FrameMerging.merge(FrameMerge.Way(base: 1, use: Array(1...5), align: .camera, alignOn: on, combine: .mean), light: light) { frames[$0 - 1] }
        let still = try FrameMerging.merge(FrameMerge.Way(base: 1, use: Array(1...5), align: .camera, combine: .mean), light: light) { frames[$0 - 1] }
        let clean = Scene.frame(clean: true, extra: thing(0)).samples.map { Double($0) - Scene.black }
        let inside = (100, 70, 50, 50)
        let outside = (16, 140, 224, 40)
        let followedValues = FrameMergingTests.light(followed.merged, base: frames[0])
        let stillValues = FrameMergingTests.light(still.merged, base: frames[0])
        // Followed, the thing is sharp and the scene is not; lined up by the scene, the other way round.
        XCTAssertLessThan(Scene.error(followedValues, clean, width: 256, in: inside), Scene.error(stillValues, clean, width: 256, in: inside) * 0.5)
        XCTAssertLessThan(Scene.error(stillValues, clean, width: 256, in: outside), Scene.error(followedValues, clean, width: 256, in: outside) * 0.7)
    }

    func testAPartOfTheUprightFrameIsFoundOnTheSensor() {
        let rect = FrameMerge.Rect(x: 0, y: 0, width: 0.2, height: 0.1)
        XCTAssertEqual(Orientation.toSensor(rect, orientation: 1), rect)
        XCTAssertEqual(Orientation.toSensor(rect, orientation: 3), FrameMerge.Rect(x: 0.8, y: 0.9, width: 0.2, height: 0.1))
        // Turned a quarter clockwise to stand up: the upright top-left is the sensor's bottom-left.
        let six = Orientation.toSensor(rect, orientation: 6)
        XCTAssertEqual(six.x, 0, accuracy: 1e-9)
        XCTAssertEqual(six.y, 0.8, accuracy: 1e-9)
        XCTAssertEqual(six.width, 0.1, accuracy: 1e-9)
        XCTAssertEqual(six.height, 0.2, accuracy: 1e-9)
        // Turned a quarter anticlockwise: the upright top-left is the sensor's top-right.
        let eight = Orientation.toSensor(rect, orientation: 8)
        XCTAssertEqual(eight.x, 0.9, accuracy: 1e-9)
        XCTAssertEqual(eight.y, 0, accuracy: 1e-9)
    }

    func testALinearRawPictureTakesTheBayerPicturesPlace() throws {
        let width = 120
        let height = 80
        let file = TestDNG.make(samples: DNGTests.mosaic(width: width, height: height), width: width, height: height, tile: (40, 24), compressed: true, bigEndian: true)
        // Large enough to need several strips.
        let picture = RGBFrame(
            width: width * 8, height: height * 8, samples: (0..<(width * height * 192)).map { UInt16($0 % 60000) }, blackLevel: 8448, whiteLevel: 65520)
        let written = try DNG.replacingFrame(of: file, with: picture)
        let tags = try XCTUnwrap(LinearTags(written))
        XCTAssertEqual(tags.values[262], [34892], "linear raw")
        XCTAssertEqual(tags.values[277], [3])
        XCTAssertEqual(tags.values[258], [16, 16, 16])
        XCTAssertEqual(tags.values[256], [picture.width])
        XCTAssertEqual(tags.values[257], [picture.height])
        XCTAssertNil(tags.values[33421], "nothing of the filter pattern is left")
        XCTAssertNil(tags.values[33422])
        XCTAssertEqual(tags.values[50717], [65520, 65520, 65520])
        XCTAssertEqual(tags.strip, picture.samples, "the samples are what was given")
        XCTAssertGreaterThan(tags.values[273]?.count ?? 0, 1, "in strips of about a megabyte, not one of hundreds")
        XCTAssertEqual(TestDNG.cameraModel(of: written), "Test camera", "the rest of the file is as it was")
        // A Bayer reader no longer finds a Bayer picture in it.
        XCTAssertThrowsError(try DNG.frame(of: written))
    }
}

/// The raw picture's directory of a DNG, read plainly: each tag's whole-number values, and the
/// samples of its one strip.
private struct LinearTags {
    var values: [Int: [Int]] = [:]
    var strip: [UInt16] = []

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        let big = bytes[0] == 0x4D
        func u16(_ at: Int) -> Int { big ? Int(bytes[at]) << 8 | Int(bytes[at + 1]) : Int(bytes[at + 1]) << 8 | Int(bytes[at]) }
        func u32(_ at: Int) -> Int {
            big ? Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
                : Int(bytes[at + 3]) << 24 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 1]) << 8 | Int(bytes[at])
        }
        func directory(_ offset: Int) -> [Int: [Int]] {
            var tags: [Int: [Int]] = [:]
            for index in 0..<u16(offset) {
                let at = offset + 2 + index * 12
                let type = u16(at + 2)
                let count = u32(at + 4)
                let size = [1: 1, 3: 2, 4: 4, 5: 8][type] ?? 1
                let start = size * count <= 4 ? at + 8 : u32(at + 8)
                tags[u16(at)] = (0..<count).map { type == 3 ? u16(start + $0 * 2) : type == 4 ? u32(start + $0 * 4) : type == 5 ? u32(start + $0 * 8) / max(1, u32(start + $0 * 8 + 4)) : Int(bytes[start + $0]) }
            }
            return tags
        }
        let first = directory(u32(4))
        guard let children = first[330] else { return nil }
        for child in children {
            let tags = directory(child)
            guard tags[262] == [34892], let offsets = tags[273], let counts = tags[279], offsets.count == counts.count else { continue }
            values = tags
            strip = zip(offsets, counts).flatMap { offset, count in (0..<(count / 2)).map { UInt16(u16(offset + $0 * 2)) } }
            return
        }
        return nil
    }
}
