import Foundation
import XCTest

@testable import OscuruCore

/// Merging a shot's frames the ways the assistant can ask for: around any of them, with or
/// without some, across a bracket of exposures, lined up and combined each way, and onto a finer grid.
final class FrameMergingTests: XCTestCase {
    typealias Scene = BurstMergeTests

    /// The light above black at a photosite of a merged picture, at the base frame's brightness.
    static func light(_ merged: MergedFrame, base: RawFrame) -> [Double] {
        let scale = merged.frame.blackLevel / base.blackLevel
        return merged.frame.samples.map { Double($0) / scale - base.blackLevel }
    }

    static func light(_ merged: MergedPicture, base: RawFrame) -> [Double] {
        guard case .mosaic(let mosaic) = merged else { XCTFail("not a mosaic"); return [] }
        return light(mosaic, base: base)
    }

    static func mosaic(_ merged: MergedPicture) -> MergedFrame {
        guard case .mosaic(let mosaic) = merged else { fatalError("not a mosaic") }
        return mosaic
    }

    /// The mean of `values` over an area (x, y, width, height), one colour of the pattern only.
    static func mean(_ values: [Double], width: Int, in area: (Int, Int, Int, Int), colour: Int = 1) -> Double {
        var total = 0.0
        var count = 0.0
        for y in area.1..<(area.1 + area.3) where y % 2 == colour / 2 {
            for x in area.0..<(area.0 + area.2) where x % 2 == colour % 2 {
                total += values[y * width + x]
                count += 1
            }
        }
        return total / count
    }

    func testABracketHoldsWhatTheBaseBlewAndCleansItsShadows() throws {
        // A lamp far brighter than the base frame can hold, in every colour.
        let lamp: (Double, Double) -> Double = { x, y in x >= 96 && x < 160 && y >= 64 && y < 128 ? 9000 : 0 }
        let clean = Scene.frame(clean: true)
        let base = Scene.frame(seed: 1, extra: lamp)
        let darker = Scene.frame(dx: 2, dy: -2, seed: 2, light: 0.25, extra: { x, y in lamp(x + 2, y - 2) })
        let brighter = Scene.frame(dx: -4, dy: 2, seed: 3, light: 4, extra: { x, y in lamp(x - 4, y + 2) })
        let frames = [base, darker, brighter]
        XCTAssertEqual(FrameMerging.light(of: darker, against: base, nominal: 0.25), 0.25, accuracy: 0.02)
        XCTAssertEqual(FrameMerging.light(of: brighter, against: base, nominal: 4), 4, accuracy: 0.3)

        let result = try FrameMerging.merge(FrameMerge.Way(base: 1, use: [1, 2, 3]), light: [1, 0.25, 4]) { frames[$0 - 1] }
        let merged = Self.mosaic(result.merged)
        // The darkest frame took a quarter of the light: the file reaches two stops above the base's white.
        XCTAssertEqual(merged.brightening, 2, accuracy: 1e-9)
        let scale = merged.frame.blackLevel / base.blackLevel
        XCTAssertEqual(merged.frame.whiteLevel, (scale * (Scene.black + 4 * (Scene.white - Scene.black))).rounded(.down), accuracy: 1)
        let values = Self.light(merged, base: base)

        // Inside the lamp the base is blown; the picture is what the darker frame recorded there.
        let inside = (104, 72, 48, 48)
        XCTAssertGreaterThanOrEqual(Self.mean(base.samples.map(Double.init), width: 256, in: inside), Scene.white - 1)
        let truthAbove: [Double] = clean.samples.map { Double($0) - Scene.black }
        for colour in 0..<4 {
            let scene: Double = Self.mean(truthAbove, width: 256, in: inside, colour: colour) / Scene.gains[colour]
            let expected: Double = Scene.gains[colour] * (scene + 9000)
            XCTAssertEqual(Self.mean(values, width: 256, in: inside, colour: colour) / expected, 1, accuracy: 0.03, "colour \(colour)")
        }

        // Away from it, the brighter frame's light cleans what the base alone left noisy.
        let away = (8, 136, 240, 48)
        let truth = clean.samples.map { Double($0) - Scene.black }
        let before = Scene.error(base.samples.map { Double($0) - Scene.black }, truth, width: 256, in: away)
        let after = Scene.error(values, truth, width: 256, in: away)
        XCTAssertLessThan(after, before * 0.75, "noise \(before) → \(after)")
        XCTAssertEqual(result.reports.keys.sorted(), [2, 3])
        XCTAssertEqual(result.reports[2]?.shift ?? 0, 2 * 2.squareRoot(), accuracy: 0.01)
    }

    /// Five frames of a still scene the camera drifted over, with a bright thing crossing it:
    /// 20 photosites square, 30 further along in each frame.
    static func crossing() -> (frames: [RawFrame], clean: [Double], spot: (Int) -> (Int, Int, Int, Int)) {
        let drift: [(Double, Double)] = [(0, 0), (2, 0), (-2, 2), (4, -2), (0, 4)]
        func thing(_ index: Int) -> (Double, Double) -> Double {
            { x, y in x >= Double(40 + 30 * index) && x < Double(60 + 30 * index) && y >= 80 && y < 100 ? 1000 : 0 }
        }
        let frames = drift.enumerated().map { index, by in
            // The thing is where it is in the scene, whatever the camera did.
            Scene.frame(dx: by.0, dy: by.1, seed: UInt64(index + 1), extra: { x, y in thing(index)(x + by.0, y + by.1) })
        }
        let clean = Scene.frame(clean: true).samples.map { Double($0) - Scene.black }
        return (frames, clean, { index in (42 + 30 * index, 82, 16, 16) })
    }

    func testMovementIsFrozenAveragedRemovedOrDrawn() throws {
        let (frames, clean, spot) = Self.crossing()
        let light = [Double](repeating: 1, count: frames.count)
        func merged(_ combine: FrameMerge.Combine, base: Int = 1) throws -> (values: [Double], reports: [Int: FrameReport]) {
            let way = FrameMerge.Way(base: base, use: [1, 2, 3, 4, 5], align: FrameMerge.Way.align(for: combine), combine: combine)
            let result = try FrameMerging.merge(way, light: light) { frames[$0 - 1] }
            XCTAssertEqual(result.merged.brightening, 0)
            return (Self.light(result.merged, base: frames[base - 1]), result.reports)
        }
        func above(_ values: [Double], _ index: Int) -> Double {
            Self.mean(values, width: 256, in: spot(index)) - Self.mean(clean, width: 256, in: spot(index))
        }

        // Frozen: the thing where the base frame saw it, and nowhere else.
        let frozen = try merged(.robust)
        XCTAssertEqual(above(frozen.values, 0), 1000, accuracy: 90)
        for index in 1..<5 { XCTAssertEqual(above(frozen.values, index), 0, accuracy: 60, "frozen, place \(index)") }

        // Blurred: a fifth of it everywhere it went.
        let blurred = try merged(.mean)
        for index in 0..<5 { XCTAssertEqual(above(blurred.values, index), 200, accuracy: 60, "blurred, place \(index)") }

        // Removed: gone, and the still scene cleaner than one frame of it.
        let removed = try merged(.median)
        for index in 0..<5 { XCTAssertEqual(above(removed.values, index), 0, accuracy: 60, "removed, place \(index)") }
        let inside = (16, 16, 224, 160)
        let one = Scene.error(frames[0].samples.map { Double($0) - Scene.black }, clean, width: 256, in: (16, 110, 224, 60))
        XCTAssertLessThan(Scene.error(removed.values, clean, width: 256, in: inside), one * 0.6)
        // Each frame differs from the others where its thing was: about 400 of 49 000 photosites.
        for frame in 2...5 {
            let differs = removed.reports[frame]?.differs ?? 0
            XCTAssertGreaterThan(differs, 0.004, "frame \(frame)")
            XCTAssertLessThan(differs, 0.05, "frame \(frame)")
        }

        // Drawn: all of it everywhere it went, and the rest as still as when it is removed.
        let drawn = try merged(.brightest)
        for index in 0..<5 { XCTAssertEqual(above(drawn.values, index), 1000, accuracy: 90, "drawn, place \(index)") }
        XCTAssertLessThan(Scene.error(drawn.values, clean, width: 256, in: (16, 110, 224, 60)), one * 0.7)

        // Around another frame, the moment is that frame's: the thing where the third frame saw it
        // (which the camera's drift put two photosites off).
        let third = try merged(.robust, base: 3)
        let place = (42 + 60 + 2, 82 - 2, 16, 16)
        let still = Scene.frame(dx: -2, dy: 2, clean: true).samples.map { Double($0) - Scene.black }
        let thirdAbove: Double = Self.mean(third.values, width: 256, in: place) - Self.mean(still, width: 256, in: place)
        XCTAssertEqual(thirdAbove, 1000, accuracy: 90)
        // More caution averages less.
        XCTAssertGreaterThan(FrameMerge.Way(base: 1, use: [1, 2], caution: 0).tolerance, FrameMerge.Way(base: 1, use: [1, 2], caution: 1).tolerance * 8)
    }

    func testTheCameraMakesASetAndItsOwnMerge() throws {
        let frames = [
            Scene.frame(seed: 1), Scene.frame(dx: 2, dy: 0, seed: 2, light: 0.25), Scene.frame(dx: 0, dy: 2, seed: 3, light: 4), Scene.frame(dx: -2, dy: 0, seed: 4),
        ]
        let times: [Double] = [1.0 / 30, 1.0 / 120, 1.0 / 8, 1.0 / 30]
        var shots: [FrameSet.Shot] = []
        for (index, time) in times.enumerated() { shots.append(FrameSet.Shot(time: time, iso: 100, after: Double(index) * 0.1)) }
        let made = try FrameSet.make(frames: frames, shots: shots)
        XCTAssertEqual(made.set.frames.count, 4)
        XCTAssertEqual(made.set.frames[1].light, 0.25, accuracy: 0.02)
        XCTAssertEqual(made.set.frames[2].light, 4, accuracy: 0.4)
        // Built on a frame at the shot's own exposure, with every frame in it.
        XCTAssertTrue([1, 4].contains(made.set.merge.base))
        XCTAssertNotEqual(made.set.merge.base, 2)
        XCTAssertNotEqual(made.set.merge.base, 3)
        XCTAssertEqual(made.set.merge.use, [1, 2, 3, 4])
        XCTAssertEqual(made.merged.brightening, made.set.brightening(of: made.set.merge), accuracy: 0.01)
        XCTAssertEqual(made.merged.brightening, 2, accuracy: 0.15)
        XCTAssertEqual(made.set.brightening(of: .single(2)), 0)
        // The brighter frame is blown in places; the others are not.
        XCTAssertGreaterThan(made.set.frames[2].blown, 0.05)
        XCTAssertLessThan(made.set.frames[0].blown, 0.001)
        let sharpest: Double = made.set.frames.map { $0.sharpness }.max() ?? 0
        XCTAssertEqual(sharpest, 1, accuracy: 1e-9)
        let listed = made.set.json(with: FrameMerge.Way(base: 4, use: [1, 4]))
        XCTAssertEqual(listed.arrayValue?.count, 4)
        let stops: Double = listed.arrayValue?[1]["stops"]?.doubleValue ?? 0
        XCTAssertEqual(stops, -2, accuracy: 0.15)
        let entries: [JSONValue] = listed.arrayValue ?? []
        XCTAssertEqual(entries[1]["used"], JSONValue.bool(false))
        XCTAssertEqual(entries[3]["base"], JSONValue.bool(true))
        // It survives being written and read.
        XCTAssertEqual(try JSONDecoder().decode(FrameSet.self, from: JSONEncoder().encode(made.set)), made.set)
    }

    func testTheWayFramesAreMergedIsAPhotoSetting() throws {
        let camera = FrameMerge(way: FrameMerge.Way(base: 2, use: [1, 2, 3, 4]))
        var state = EditingState(defaults: PhotoDefaults(frames: camera))
        XCTAssertEqual(state.frames, camera)
        var plain = EditingState()
        XCTAssertThrowsError(try plain.setFrames(["combine": "mean"], count: 4)) { XCTAssertTrue("\($0)".contains("no frames to merge")) }

        // A way of combining brings the lining up that goes with it, unless one is given.
        try state.setFrames(["combine": "median"], count: 4)
        XCTAssertEqual(state.frames?.way, FrameMerge.Way(base: 2, use: [1, 2, 3, 4], align: .camera, combine: .median))
        try state.setFrames(["combine": "mean", "align": "none"], count: 4)
        XCTAssertEqual(state.frames?.way.align, FrameMerge.Align.none)
        try state.setFrames(["base": 3, "use": [4, 3, 1], "combine": "robust", "caution": 0.8], count: 4)
        XCTAssertEqual(state.frames?.way, FrameMerge.Way(base: 3, use: [1, 3, 4], align: .tiles, combine: .robust, caution: 0.8))
        // Following one part of the frame is for lining up by the camera.
        XCTAssertThrowsError(try state.setFrames(["alignOn": ["x": 0.4, "y": 0.4, "width": 0.2, "height": 0.2]], count: 4)) { XCTAssertTrue("\($0)".contains("only align")) }
        var panned = state
        try panned.setFrames(["combine": "mean", "alignOn": ["x": 0.4, "y": 0.4, "width": 0.2, "height": 0.2], "scale": 2], count: 4)
        XCTAssertEqual(panned.frames?.way.alignOn, FrameMerge.Rect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))
        XCTAssertEqual(panned.frames?.way.scale, 2)
        XCTAssertThrowsError(try panned.setFrames(["scale": 3], count: 4))
        XCTAssertThrowsError(try panned.setFrames(["alignOn": ["x": 0.9, "y": 0.4, "width": 0.2, "height": 0.2]], count: 4))
        // A way an earlier version saved, with a movement, reads as align and combine.
        let saved = try JSONDecoder().decode(FrameMerge.Way.self, from: Data(#"{"base":2,"use":[1,2],"movement":"trails","caution":0.5}"#.utf8))
        XCTAssertEqual(saved, FrameMerge.Way(base: 2, use: [1, 2], align: .camera, combine: .brightest))
        var legacy = state
        try legacy.setFrames(["movement": "remove"], count: 4)
        XCTAssertEqual(legacy.frames?.way.combine, .median)
        // The base must be one of the frames used, and frames must be of the shot.
        XCTAssertThrowsError(try state.setFrames(["use": [1, 4]], count: 4)) { XCTAssertTrue("\($0)".contains("not among the frames used")) }
        XCTAssertThrowsError(try state.setFrames(["base": 5], count: 4))
        XCTAssertThrowsError(try state.setFrames(["use": [1, 1, 3]], count: 4))
        XCTAssertThrowsError(try state.setFrames(["combine": "smear"], count: 4))
        XCTAssertThrowsError(try state.setFrames(["strength": 1], count: 4))
        XCTAssertEqual(state.frames?.way, FrameMerge.Way(base: 3, use: [1, 3, 4], align: .tiles, combine: .robust, caution: 0.8), "a refused change changes nothing")

        // A part of the picture merged another way starts from the picture's own.
        try state.setFrames(["use": "all", "areas": [["mask": ["area": ["type": "subject"]], "combine": "mean"]]], count: 4)
        XCTAssertEqual(state.frames?.areas.count, 1)
        XCTAssertEqual(state.frames?.areas.first?.way, FrameMerge.Way(base: 3, use: [1, 2, 3, 4], align: .camera, combine: .mean, caution: 0.8))
        XCTAssertThrowsError(try state.setFrames(["areas": [["combine": "mean"]]], count: 4)) { XCTAssertTrue("\($0)".contains("mask is required")) }
        let area: JSONValue = ["mask": ["area": ["type": "subject"]], "combine": "mean"]
        XCTAssertThrowsError(try state.setFrames(["areas": [area, area, area, area]], count: 4))

        // Scripts and saved photos see it in the state; versions that differ in it differ.
        XCTAssertEqual(state.json["frames"]?["combine"], "robust")
        XCTAssertEqual(state.json["frames"]?["areas"]?.arrayValue?.first?["combine"], "mean")
        XCTAssertEqual(try EditingState(json: state.json).frames, state.frames)
        XCTAssertEqual(try JSONDecoder().decode(EditingState.self, from: JSONEncoder().encode(state)), state)
        let untouched = EditingState(defaults: PhotoDefaults(frames: camera))
        XCTAssertTrue(state.changes(from: untouched).contains { $0.path == "frames.base" })
        XCTAssertNil(EditingState().json["frames"])
        try state.reset(section: "frames", defaults: PhotoDefaults(frames: camera))
        XCTAssertEqual(state.frames, camera)

        // Each way has a name of its own for its file; one frame alone is that frame.
        XCTAssertEqual(FrameMerge.Way.single(3).key, "frame 3")
        XCTAssertNotEqual(FrameMerge.Way(base: 1, use: [1, 2]).key, FrameMerge.Way(base: 2, use: [1, 2]).key)
        XCTAssertNotEqual(FrameMerge.Way(base: 1, use: [1, 2], caution: 0.2).key, FrameMerge.Way(base: 1, use: [1, 2], caution: 0.8).key)
        XCTAssertEqual(FrameMerge.Way(base: 1, use: [1, 2], align: .camera, combine: .mean, caution: 0.2).key, FrameMerge.Way(base: 1, use: [1, 2], align: .camera, combine: .mean, caution: 0.8).key)
        XCTAssertNotEqual(FrameMerge.Way(base: 1, use: [1, 2]).key, FrameMerge.Way(base: 1, use: [1, 2], scale: 2).key)
        XCTAssertNotEqual(FrameMerge.Way(base: 1, use: [1, 2], align: .camera).key, FrameMerge.Way(base: 1, use: [1, 2], align: .none).key)
        XCTAssertFalse(FrameMerge.Way(base: 1, use: [1], scale: 2).isSingle, "one frame on a finer grid is still made")
    }
}
