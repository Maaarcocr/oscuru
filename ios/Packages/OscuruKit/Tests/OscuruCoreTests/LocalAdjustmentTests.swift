import Foundation
import XCTest

@testable import OscuruCore

/// Grain, halation and local adjustments: their settings, masks, saved form and what they render as.
final class LocalAdjustmentTests: XCTestCase {
    private let radial: JSONValue = ["area": ["type": "radial", "x": 0.5, "y": 0.4, "width": 0.3, "height": 0.5]]

    private func assertError(_ work: @autoclosure () throws -> Void, contains parts: String..., file: StaticString = #filePath, line: UInt = #line) {
        do {
            try work()
            XCTFail("expected a StateError", file: file, line: line)
        } catch let error as StateError {
            for part in parts { XCTAssertTrue(error.message.contains(part), "\"\(error.message)\" should contain \"\(part)\"", file: file, line: line) }
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    // MARK: Grain and halation

    func testGrainAndHalationStartOffAndAreValidated() throws {
        var state = EditingState()
        XCTAssertEqual(state.grain, ["amount": 0, "size": 25, "roughness": 50])
        XCTAssertEqual(state.halation, ["amount": 0, "radius": 30, "threshold": 70])
        try state.setGrain(["amount": 30, "size": 60])
        try state.setHalation(["amount": 20])
        XCTAssertEqual(state.grain["amount"], 30)
        XCTAssertEqual(state.grain["roughness"], 50, "values left out keep theirs")
        XCTAssertEqual(state.halation["amount"], 20)
        assertError(try state.setGrain(["amount": 120]), contains: "grain.amount must be between 0 and 100")
        assertError(try state.setHalation(["glow": 1]), contains: "halation has no setting \"glow\"")
        XCTAssertEqual(state.changes(from: EditingState()).map(\.path), ["grain.amount", "grain.size", "halation.amount"])
        try state.reset(section: "effects", defaults: PhotoDefaults())
        XCTAssertEqual(state, EditingState())
    }

    // MARK: Local adjustments

    func testALocalAdjustmentIsCreatedWithAMaskThenChangedByName() throws {
        var state = EditingState()
        try state.setLocal(name: "pagoda", settings: ["mask": radial, "adjust": ["exposureEV": 0.5, "clarity": 20]])
        XCTAssertEqual(state.local.count, 1)
        XCTAssertEqual(state.local[0].adjust["exposureEV"], 0.5)
        XCTAssertEqual(state.local[0].adjust["contrast"], 0, "values not given start at 0")
        XCTAssertEqual(state.local[0].mask.area.type, "radial")
        XCTAssertEqual(state.local[0].mask.area.feather, 0.5, "feather defaults to soft")

        // The same name, in any case, changes it: values given replace theirs, the rest stay.
        try state.setLocal(name: "Pagoda ", settings: ["adjust": ["exposureEV": 0.3, "dehaze": 15]])
        XCTAssertEqual(state.local.count, 1)
        XCTAssertEqual(state.local[0].adjust["exposureEV"], 0.3)
        XCTAssertEqual(state.local[0].adjust["clarity"], 20)
        XCTAssertEqual(state.local[0].adjust["dehaze"], 15)
        XCTAssertEqual(state.local[0].name, "pagoda")

        // A new mask replaces the old one.
        try state.setLocal(name: "pagoda", settings: ["mask": ["area": ["type": "subject"], "luminance": ["from": 0.2, "to": 0.8]]])
        XCTAssertEqual(state.local[0].mask.area.type, "subject")
        XCTAssertEqual(state.local[0].mask.luminance, LuminanceRange(from: 0.2, to: 0.8, feather: 0.1))
        XCTAssertEqual(state.local[0].adjust["clarity"], 20)

        XCTAssertEqual(try state.localAdjustment(named: "PAGODA").name, "pagoda")
        try state.removeLocal(name: "pagoda")
        XCTAssertTrue(state.local.isEmpty)
    }

    func testLocalAdjustmentMistakesAreExplained() throws {
        var state = EditingState()
        assertError(try state.setLocal(name: "sky", settings: ["adjust": ["exposureEV": -0.5]]), contains: "does not exist yet, so it needs a mask")
        assertError(try state.setLocal(name: "", settings: ["mask": radial]), contains: "needs a name")
        assertError(try state.setLocal(name: "sky", settings: ["mask": radial, "adjust": ["exposureEV": 9]]), contains: "adjust.exposureEV must be between -4 and 4")
        assertError(try state.setLocal(name: "sky", settings: ["mask": radial, "brush": 1]), contains: "has no setting \"brush\"")
        assertError(try state.setLocal(name: "sky", settings: ["mask": ["area": ["type": "sky"]]]), contains: "area.type must be one of", "\"radial\"", "got \"sky\"")
        assertError(try state.setLocal(name: "sky", settings: ["mask": ["area": ["type": "radial", "x": 0.5]]]), contains: "needs x, y, width and height")
        assertError(
            try state.setLocal(name: "sky", settings: ["mask": ["area": ["type": "linear", "from": [0.5, 0.2], "to": [0.5, 0.2]]]]),
            contains: "at least 0.01 apart")
        assertError(try state.setLocal(name: "sky", settings: ["mask": ["area": ["type": "linear", "from": [0.5], "to": [0.5, 0.2]]]]), contains: "from must be an [x, y] point")
        assertError(try state.setLocal(name: "sky", settings: ["mask": ["area": ["type": "frame"], "luminance": ["from": 0.6, "to": 0.4]]]), contains: "luminance.to must be above from")
        assertError(try state.setLocal(name: "sky", settings: ["mask": ["area": ["type": "frame"], "color": ["hue": 400]]]), contains: "color.hue must be between 0 and 360")
        assertError(try state.setLocal(name: "sky", settings: ["mask": ["area": ["type": "subject", "x": 0.5]]]), contains: "has no setting \"x\"")
        assertError(try state.removeLocal(name: "sky"), contains: "no local adjustment named", "Existing: none")
        XCTAssertTrue(state.local.isEmpty, "nothing half-made is left behind")

        for index in 0..<Specs.maxLocalAdjustments { try state.setLocal(name: .string("area \(index)"), settings: ["mask": radial]) }
        assertError(try state.setLocal(name: "one more", settings: ["mask": radial]), contains: "at most \(Specs.maxLocalAdjustments) local adjustments")
    }

    func testMasksComeBackAsTheyWereGiven() throws {
        var state = EditingState()
        try state.setLocal(
            name: "sky",
            settings: [
                "mask": ["area": ["type": "linear", "from": [0.5, 0], "to": [0.5, 0.45]], "color": ["hue": 215, "range": 80], "invert": false],
                "adjust": ["exposureEV": -0.4, "saturation": 10],
            ])
        try state.setLocal(name: "edges", settings: ["mask": ["area": ["type": "radial", "x": 0.5, "y": 0.5, "width": 0.9, "height": 0.9, "angle": 10, "feather": 0.8], "invert": true]])
        let json = state.json["local"]?.arrayValue ?? []
        XCTAssertEqual(json.count, 2)
        XCTAssertEqual(json[0]["name"], "sky")
        XCTAssertEqual(json[0]["mask"]?["area"], ["type": "linear", "from": [0.5, 0], "to": [0.5, 0.45]])
        XCTAssertEqual(json[0]["mask"]?["color"], ["hue": 215, "range": 80])
        XCTAssertNil(json[0]["mask"]?["luminance"])
        XCTAssertEqual(json[1]["mask"]?["invert"], true)
        XCTAssertEqual(json[1]["mask"]?["area"]?["angle"], 10)

        // Through the script-facing JSON and through a saved document, the state is unchanged.
        XCTAssertEqual(try EditingState(json: state.json), state)
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(EditingState.self, from: data), state)
        XCTAssertEqual(state.changes(from: EditingState()).map(\.path), ["local"])
        try state.reset(section: "local", defaults: PhotoDefaults())
        XCTAssertTrue(state.local.isEmpty)
    }

    func testStatesSavedBeforeTheseExistedStillOpen() throws {
        var old = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(EditingState()))
        guard var members = old.objectValue else { return XCTFail("not an object") }
        members["grain"] = nil
        members["halation"] = nil
        members["local"] = nil
        old = .object(members)
        let decoded = try JSONDecoder().decode(EditingState.self, from: try JSONEncoder().encode(old))
        XCTAssertEqual(decoded, EditingState())
    }

    func testMasksJoinCutAndDrawByHand() throws {
        var state = EditingState()
        // Tap the tower, join its spire, cut the tree in front out with a brush, snap to the edges.
        try state.setLocal(
            name: "tower",
            settings: [
                "mask": [
                    "area": [
                        ["type": "object", "points": [[0.72, 0.36], [0.71, 0.08]], "exclude": [[0.48, 0.31]]],
                        ["type": "outline", "points": [[0.7, 0.0], [0.73, 0.0], [0.73, 0.12], [0.7, 0.12]]],
                    ],
                    "subtract": ["type": "brush", "strokes": [[[0.6, 0.5], [0.62, 0.55]], [[0.5, 0.4]]], "size": 0.02],
                    "intersect": [["type": "frame"]],
                    "luminance": ["from": 0, "to": 0.6], "measure": "original", "grow": 0.002, "refine": 0.5,
                ],
                "adjust": ["dehaze": 20],
            ])
        let mask = try state.localAdjustment(named: "tower").mask
        XCTAssertEqual(mask.areas.map(\.type), ["object", "outline"])
        XCTAssertEqual(mask.area.exclude, [[0.48, 0.31]])
        XCTAssertEqual(mask.subtract.first?.strokes.count, 2)
        XCTAssertEqual(mask.subtract.first?.feather ?? 0, 0.005, accuracy: 1e-9, "a brush's edge is a quarter of its size unless given")
        XCTAssertEqual(mask.add.first?.feather ?? 0, 0.003, accuracy: 1e-9)
        XCTAssertEqual(mask.measure, "original")
        XCTAssertEqual(mask.refine, 0.5)
        // It reads back the way scripts write it, and saves and opens unchanged.
        let json = state.json["local"]?.arrayValue?.first?["mask"]
        XCTAssertEqual(json?["area"]?.arrayValue?.count, 2)
        XCTAssertEqual(json?["subtract"]?.arrayValue?.first?["type"], "brush")
        XCTAssertEqual(try EditingState(json: state.json), state)
        XCTAssertEqual(try JSONDecoder().decode(EditingState.self, from: JSONEncoder().encode(state)), state)

        // Mistakes say what to do.
        func set(_ mask: JSONValue) throws { try state.setLocal(name: "x", settings: ["mask": mask]) }
        assertError(try set(["area": ["type": "object"]]), contains: "points must be a list of 1 to 16")
        assertError(try set(["area": ["type": "object", "points": [[1.2, 0.5]]]]), contains: "points[0][0]")
        assertError(try set(["area": ["type": "outline", "points": [[0, 0], [1, 1]]]]), contains: "3 to 400")
        assertError(try set(["area": ["type": "brush", "strokes": []]]), contains: "1 to 40 strokes")
        assertError(try set(["area": .array([])]), contains: "1 to 8 areas")
        assertError(try set(["area": ["type": "frame"], "measure": "before"]), contains: "\"current\" or \"original\"")
        assertError(try set(["area": ["type": "frame"], "grow": 0.2]), contains: "grow")

        // A mask saved before any of this opens as it was.
        var old = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(Mask(area: MaskArea(type: "linear"))))
        guard var members = old.objectValue, var area = members["area"]?.objectValue else { return XCTFail("not an object") }
        for key in ["add", "subtract", "intersect", "measure", "grow", "refine"] { members[key] = nil }
        for key in ["points", "exclude", "strokes", "size"] { area[key] = nil }
        members["area"] = .object(area)
        old = .object(members)
        XCTAssertEqual(try JSONDecoder().decode(Mask.self, from: JSONEncoder().encode(old)), Mask(area: MaskArea(type: "linear")))
    }

    func testSnappingMovesAMasksEdgeOntoThePhotosEdge() {
        // A photo dark on the left and bright from x = 210; a soft mask rising from x = 180 to 220.
        let width = 400
        let height = 20
        var guide = [Float](repeating: 0, count: width * height)
        var mask = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                guide[y * width + x] = x < 210 ? 0.1 : 0.9
                mask[y * width + x] = Float(min(1, max(0, Double(x - 180) / 40)))
            }
        }
        let snapped = EdgeSnap.snap(mask: mask, guide: guide, width: width, height: height, strength: 0.6)
        func at(_ values: [Float], _ x: Int) -> Float { values[10 * width + x] }
        // The step now happens at the photo's edge, not spread across the ramp.
        XCTAssertGreaterThan(at(snapped, 212) - at(snapped, 207), 0.25)
        XCTAssertLessThan(at(mask, 212) - at(mask, 207), 0.15)
        // Far from it nothing changes.
        XCTAssertEqual(at(snapped, 20), 0, accuracy: 0.01)
        XCTAssertEqual(at(snapped, 380), 1, accuracy: 0.01)
        // Where the photo is flat, a guided filter keeps a flat mask flat.
        let flat = EdgeSnap.guided(mask: [Float](repeating: 0.3, count: 100), guide: [Float](repeating: 0.5, count: 100), width: 10, height: 10, radius: 2, epsilon: 0.001)
        for value in flat { XCTAssertEqual(value, 0.3, accuracy: 1e-4) }
    }

    // MARK: Filters

    func testALookCarriesGrainAndHalationButNotLocalAdjustments() throws {
        var state = EditingState()
        try state.setGrain(["amount": 25])
        try state.setHalation(["amount": 15])
        try state.setLocal(name: "pagoda", settings: ["mask": radial, "adjust": ["exposureEV": 0.5]])
        let look = Look(state: state, defaults: PhotoDefaults())
        let applied = look.applied(to: EditingState(), defaults: PhotoDefaults())
        XCTAssertEqual(applied.grain["amount"], 25)
        XCTAssertEqual(applied.halation["amount"], 15)
        XCTAssertTrue(applied.local.isEmpty, "local adjustments belong to the photo they were made on")

        // Filters saved before grain existed have none.
        var json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(look))
        guard var members = json.objectValue else { return XCTFail("not an object") }
        members["grain"] = nil
        members["halation"] = nil
        json = .object(members)
        let old = try JSONDecoder().decode(Look.self, from: JSONEncoder().encode(json))
        XCTAssertEqual(old.grain["amount"], 0)
        XCTAssertEqual(old.halation["amount"], 0)
    }

    // MARK: Pipeline

    func testLocalToneChangesNothingAtZeroAndNeverReversesTones() {
        let none = ColorPipeline.localTone(EditingState.defaults(Specs.localAdjustments))
        for step in 0...100 {
            let x = Double(step) / 100
            XCTAssertEqual(none(x), x, accuracy: 1e-9)
        }
        XCTAssertNil(ColorPipeline.localToneTable(["saturation": 30, "clarity": 20]), "no tone change, no table")

        let extremes: [[String: Double]] = [
            ["exposureEV": 4, "contrast": 100, "highlights": 100, "shadows": 100, "dehaze": 100],
            ["exposureEV": -4, "contrast": -100, "highlights": -100, "shadows": -100, "dehaze": -100],
            ["exposureEV": 1.5, "highlights": -100, "shadows": 100],
        ]
        for adjust in extremes {
            let tone = ColorPipeline.localTone(adjust)
            var previous = -1.0
            for step in 0...1000 {
                let y = tone(Double(step) / 1000)
                XCTAssertGreaterThanOrEqual(y, previous - 1e-9, "\(adjust) reverses tones")
                previous = y
            }
        }
    }

    func testLocalExposureWorksInLightAndKeepsWhiteAtWhite() {
        let brighter = ColorPipeline.localTone(["exposureEV": 1])
        let darker = ColorPipeline.localTone(["exposureEV": -1])
        let dark = ColorPipeline.encode(0.02)
        XCTAssertEqual(ColorPipeline.decode(brighter(dark)), 0.04, accuracy: 0.002, "a stop up doubles dark light")
        XCTAssertEqual(ColorPipeline.decode(darker(ColorPipeline.encode(0.4))), 0.2, accuracy: 0.002, "a stop down halves light")
        XCTAssertEqual(brighter(1), 1, accuracy: 1e-9, "white stays white instead of clipping")
        XCTAssertGreaterThan(brighter(0.5), 0.6)
    }

    func testWhiteBalanceGainsWarmOrCoolWithoutChangingBrightness() {
        XCTAssertEqual(ColorPipeline.whiteBalanceGains(temperature: 0, tint: 0), [1, 1, 1])
        for (temperature, tint) in [(60.0, 0.0), (-100.0, 40.0), (0.0, -100.0)] {
            let gains = ColorPipeline.whiteBalanceGains(temperature: temperature, tint: tint)
            XCTAssertEqual(0.2126 * gains[0] + 0.7152 * gains[1] + 0.0722 * gains[2], 1, accuracy: 1e-9)
        }
        let warm = ColorPipeline.whiteBalanceGains(temperature: 60, tint: 0)
        XCTAssertGreaterThan(warm[0], warm[2])
        let magenta = ColorPipeline.whiteBalanceGains(temperature: 0, tint: 60)
        XCTAssertLessThan(magenta[1], magenta[0])
    }

    func testRangesKeepTheTonesAndColoursAsked() {
        let mids = LuminanceRange(from: 0.3, to: 0.7, feather: 0.05)
        XCTAssertEqual(ColorPipeline.rangeWeight(0.5, 0.5, 0.5, luminance: mids, color: nil), 1, accuracy: 1e-9)
        XCTAssertEqual(ColorPipeline.rangeWeight(0.1, 0.1, 0.1, luminance: mids, color: nil), 0, accuracy: 1e-9)
        XCTAssertEqual(ColorPipeline.rangeWeight(0.95, 0.95, 0.95, luminance: mids, color: nil), 0, accuracy: 1e-9)
        let shadows = LuminanceRange(from: 0, to: 0.3, feather: 0.05)
        XCTAssertEqual(ColorPipeline.rangeWeight(0, 0, 0, luminance: shadows, color: nil), 1, "a range from 0 keeps black fully")

        let reds = HueRange(hue: 0, range: 60)
        XCTAssertEqual(ColorPipeline.rangeWeight(0.8, 0.1, 0.1, luminance: nil, color: reds), 1, accuracy: 1e-9)
        XCTAssertEqual(ColorPipeline.rangeWeight(0.8, 0.1, 0.15, luminance: nil, color: reds), 1, accuracy: 1e-9, "the wheel wraps round at red")
        XCTAssertEqual(ColorPipeline.rangeWeight(0.1, 0.8, 0.1, luminance: nil, color: reds), 0, accuracy: 1e-9)
        XCTAssertEqual(ColorPipeline.rangeWeight(0.5, 0.5, 0.5, luminance: nil, color: reds), 0, accuracy: 1e-9, "greys have no hue")

        XCTAssertNil(ColorPipeline.rangeMaskCube(luminance: nil, color: nil))
        let cube = ColorPipeline.rangeMaskCube(luminance: mids, color: nil, size: 9)
        XCTAssertEqual(cube?.count, 9 * 9 * 9 * 4)
        XCTAssertEqual(cube?[0], 0, "black is outside the midtones")
    }

    func testRecipeCarriesOnlyWhatIsSwitchedOn() throws {
        XCTAssertNil(RenderRecipe(state: EditingState(), defaults: PhotoDefaults()).grain)
        var state = EditingState()
        try state.setGrain(["amount": 50, "size": 100])
        try state.setHalation(["amount": 40, "threshold": 100])
        try state.setLocal(name: "nothing yet", settings: ["mask": radial])
        try state.setLocal(name: "sky", settings: ["mask": ["area": ["type": "frame"], "luminance": ["from": 0.6, "to": 1]], "adjust": ["exposureEV": -0.5, "temperature": -20]])
        let recipe = RenderRecipe(state: state, defaults: PhotoDefaults())
        XCTAssertEqual(recipe.grain?.strength ?? 0, 0.06, accuracy: 1e-9)
        XCTAssertEqual(recipe.grain?.size ?? 0, 0.00275, accuracy: 1e-9)
        XCTAssertEqual(recipe.halation?.threshold ?? 0, ColorPipeline.decode(0.95), accuracy: 1e-9)
        XCTAssertEqual(recipe.local.count, 1, "a local adjustment that changes nothing is not rendered")
        let pass = recipe.local[0]
        XCTAssertEqual(pass.toneTableSize, ColorPipeline.toneTableSize)
        XCTAssertNotNil(pass.gains)
        XCTAssertEqual(pass.saturation, 1)
        XCTAssertEqual(pass.mask.luminance?.from, 0.6)
    }
}
