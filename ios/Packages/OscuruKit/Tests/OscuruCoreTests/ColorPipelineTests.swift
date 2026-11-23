import Foundation
import XCTest

@testable import OscuruCore

final class ColorPipelineTests: XCTestCase {
    private let base = EditingState()

    private func saturation(of color: RGB) -> Double {
        max(color.0, color.1, color.2) - min(color.0, color.1, color.2)
    }

    private func luma(_ color: RGB) -> Double {
        ColorPipeline.luma(color.0, color.1, color.2)
    }

    private func assertNeverReversesTones(_ tone: (Double) -> Double, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        var previous = -1.0
        for step in 0...500 {
            let y = tone(Double(step) / 500)
            XCTAssertGreaterThanOrEqual(y, 0, what, file: file, line: line)
            XCTAssertLessThanOrEqual(y, 1, what, file: file, line: line)
            XCTAssertGreaterThanOrEqual(y, previous - 1e-9, "\(what) reverses at \(Double(step) / 500)", file: file, line: line)
            previous = y
        }
    }

    // MARK: Constants

    func testTableSizesAndRangeCentres() {
        XCTAssertEqual(ColorPipeline.toneTableSize, 1024)
        XCTAssertEqual(ColorPipeline.cubeSize, 33)
        XCTAssertEqual(ColorPipeline.rangeHues, [0, 30, 60, 120, 180, 240, 270, 300])
        XCTAssertEqual(ColorPipeline.rangeHues.count, Specs.colorRanges.count)
    }

    func testLumaWeightsAddUpToOne() {
        XCTAssertEqual(ColorPipeline.luma(1, 1, 1), 1, accuracy: 1e-12)
        XCTAssertEqual(ColorPipeline.luma(0, 0, 0), 0)
        XCTAssertEqual(ColorPipeline.luma(1, 0, 0), 0.229, accuracy: 1e-12)
        XCTAssertEqual(ColorPipeline.luma(0, 1, 0), 0.6917, accuracy: 1e-12)
        XCTAssertEqual(ColorPipeline.luma(0, 0, 1), 0.0793, accuracy: 1e-12)
    }

    // MARK: Curves

    func testCurvesPassThroughTheirControlPointsWithoutOvershooting() {
        let points: [[Double]] = [[0, 0.03], [0.25, 0.21], [0.5, 0.5], [0.75, 0.8], [1, 0.98]]
        let curve = ColorPipeline.curve(points)
        for point in points { XCTAssertEqual(curve(point[0]), point[1], accuracy: 5e-7) }
        var previous = -1.0
        for step in 0...200 {
            let y = curve(Double(step) / 200)
            XCTAssertGreaterThanOrEqual(y, previous - 1e-9)
            previous = y
        }
    }

    func testCurvesNeverOvershootBetweenSteepAndFlatSegments() {
        // A plain cubic through these points would dip below 0 and rise above 1.
        let curve = ColorPipeline.curve([[0, 0], [0.45, 0.02], [0.55, 0.98], [1, 1]])
        var previous = -1.0
        for step in 0...1000 {
            let y = curve(Double(step) / 1000)
            XCTAssertGreaterThanOrEqual(y, 0)
            XCTAssertLessThanOrEqual(y, 1)
            XCTAssertGreaterThanOrEqual(y, previous - 1e-9)
            previous = y
        }
    }

    func testCurvesStayFlatOutsideTheFirstAndLastPointAndBetweenEqualPoints() {
        let curve = ColorPipeline.curve([[0.2, 0.1], [0.5, 0.6], [0.7, 0.6], [0.9, 1]])
        XCTAssertEqual(curve(0), 0.1)
        XCTAssertEqual(curve(0.1), 0.1)
        XCTAssertEqual(curve(0.2), 0.1)
        XCTAssertEqual(curve(0.9), 1)
        XCTAssertEqual(curve(1), 1)
        XCTAssertEqual(curve(0.6), 0.6, accuracy: 5e-7)
        XCTAssertEqual(curve(0.65), 0.6, accuracy: 5e-7)
    }

    func testCurvesMayGoDownAsWellAsUp() {
        let invert = ColorPipeline.curve([[0, 1], [1, 0]])
        XCTAssertEqual(invert(0), 1)
        XCTAssertEqual(invert(0.25), 0.75, accuracy: 5e-7)
        XCTAssertEqual(invert(1), 0)
    }

    func testATwoPointCurveIsAStraightLine() {
        let line = ColorPipeline.curve([[0, 0.1], [1, 0.9]])
        for step in 0...10 {
            let x = Double(step) / 10
            XCTAssertEqual(line(x), 0.1 + 0.8 * x, accuracy: 1e-9)
        }
    }

    // MARK: Tone stage

    func testToneStageIsSkippedForAnUntouchedPhotoAndForSettingsHandledElsewhere() throws {
        XCTAssertNil(ColorPipeline.toneTables(base))
        let elsewhere = try global(["exposureEV": 1, "temperature": 5000, "tint": 10, "highlights": -50, "shadows": 40, "saturation": 20, "vibrance": 20, "clarity": 10, "texture": 10, "vignette": -20])
        XCTAssertNil(ColorPipeline.toneTables(elsewhere))
        assertColor(ColorPipeline.apply(base, to: (0.3, 0.6, 0.9)), (0.3, 0.6, 0.9))
    }

    func testToneStageIsSkippedForCurvesThatLieOnTheDiagonal() throws {
        let state = try edited { try $0.setCurve(channel: "rgb", points: [[0, 0], [0.25, 0.25], [0.5, 0.5], [1, 1]]) }
        XCTAssertNil(ColorPipeline.toneTables(state))
    }

    func testEveryToneSettingAndEveryCurveSwitchesTheToneStageOn() throws {
        for (key, value) in [("contrast", 10.0), ("whites", -10), ("blacks", 10), ("dehaze", 10), ("dehaze", -10), ("highlights", 10), ("shadows", -10)] {
            XCTAssertNotNil(ColorPipeline.toneTables(try global(.object([key: .number(value)]))), "\(key) \(value)")
        }
        for channel in Specs.curveChannels {
            let state = try edited { try $0.setCurve(channel: .string(channel), points: [[0, 0.05], [1, 1]]) }
            XCTAssertNotNil(ColorPipeline.toneTables(state), channel)
        }
    }

    func testBasicToneLeavesValuesAloneForAnUntouchedPhoto() {
        let tone = ColorPipeline.basicTone(base)
        for step in 0...20 { XCTAssertEqual(tone(Double(step) / 20), Double(step) / 20) }
    }

    func testToneSettingsNeverReverseTonesAtEitherExtreme() throws {
        for key in ["contrast", "whites", "blacks", "dehaze", "highlights", "shadows"] {
            for value in [-100.0, 100] {
                let tone = ColorPipeline.basicTone(try global(.object([key: .number(value)])))
                assertNeverReversesTones(tone, "\(key) \(value)")
            }
        }
    }

    func testToneSettingsNeverReverseTonesWhenCombinedAtTheirExtremes() throws {
        for sign in [-100.0, 100] {
            let state = try global([
                "contrast": .number(sign), "whites": .number(sign), "blacks": .number(-sign), "dehaze": .number(sign), "highlights": 100, "shadows": -100,
            ])
            assertNeverReversesTones(ColorPipeline.basicTone(state), "everything at \(sign)")
        }
    }

    func testContrastPivotsOnMidGrey() throws {
        let more = ColorPipeline.basicTone(try global(["contrast": 50]))
        XCTAssertEqual(more(0.5), 0.5, accuracy: 5e-7)
        XCTAssertLessThan(more(0.25), 0.25)
        XCTAssertGreaterThan(more(0.75), 0.75)
        XCTAssertEqual(more(0), 0)
        XCTAssertEqual(more(1), 1)
        let less = ColorPipeline.basicTone(try global(["contrast": -50]))
        XCTAssertEqual(less(0.5), 0.5, accuracy: 5e-7)
        XCTAssertGreaterThan(less(0.25), 0.25)
        XCTAssertLessThan(less(0.75), 0.75)
        XCTAssertGreaterThan(less(0), 0)
        XCTAssertLessThan(less(1), 1)
    }

    func testBlacksAndWhitesMoveTheirOwnEndOfTheRange() throws {
        let crushed = ColorPipeline.basicTone(try global(["blacks": -60]))
        XCTAssertLessThan(crushed(0.1), 0.05)
        XCTAssertEqual(crushed(0.9), 0.9, accuracy: 0.005)
        let lifted = ColorPipeline.basicTone(try global(["blacks": 60]))
        XCTAssertEqual(lifted(0), 0.12, accuracy: 5e-7)
        let bright = ColorPipeline.basicTone(try global(["whites": 60]))
        XCTAssertGreaterThan(bright(0.9), 0.95)
        XCTAssertEqual(bright(0.1), 0.1, accuracy: 0.005)
        XCTAssertEqual(ColorPipeline.basicTone(try global(["whites": -60]))(1), 0.88, accuracy: 5e-7)
    }

    func testDehazeDeepensBlacksWhenPositiveAndAddsAVeilWhenNegative() throws {
        let clearer = ColorPipeline.basicTone(try global(["dehaze": 50]))
        XCTAssertEqual(clearer(0.06), 0, accuracy: 1e-9)
        XCTAssertLessThan(clearer(0.3), 0.3)
        XCTAssertEqual(clearer(1), 1, accuracy: 1e-9)
        let hazier = ColorPipeline.basicTone(try global(["dehaze": -50]))
        XCTAssertGreaterThan(hazier(0), 0.1)
        XCTAssertGreaterThan(hazier(0.3), 0.3)
    }

    func testOnlyTheNonRecoveringDirectionsOfHighlightsAndShadowsArePointOperations() throws {
        XCTAssertGreaterThan(ColorPipeline.basicTone(try global(["highlights": 60]))(0.7), 0.7)
        XCTAssertEqual(ColorPipeline.basicTone(try global(["highlights": -60]))(0.7), 0.7)
        XCTAssertLessThan(ColorPipeline.basicTone(try global(["shadows": -60]))(0.3), 0.3)
        XCTAssertEqual(ColorPipeline.basicTone(try global(["shadows": 60]))(0.3), 0.3)
    }

    func testToneTablesAreInterleavedBasicToneThenMasterCurveThenEachChannel() throws {
        let state = try edited(try global(["contrast": 30])) { state in
            try state.setCurve(channel: "rgb", points: [[0, 0.1], [1, 0.9]])
            try state.setCurve(channel: "blue", points: [[0, 0], [1, 0.5]])
        }
        let table = try XCTUnwrap(ColorPipeline.toneTables(state))
        XCTAssertEqual(table.count, ColorPipeline.toneTableSize * 3)
        XCTAssertEqual(table.count, 3072)
        let last = (ColorPipeline.toneTableSize - 1) * 3
        XCTAssertEqual(Double(table[0]), 0.1, accuracy: 5e-6)
        XCTAssertEqual(Double(table[1]), 0.1, accuracy: 5e-6)
        XCTAssertEqual(Double(table[2]), 0.05, accuracy: 5e-6)
        XCTAssertEqual(Double(table[last]), 0.9, accuracy: 5e-6)
        XCTAssertEqual(Double(table[last + 1]), 0.9, accuracy: 5e-6)
        XCTAssertEqual(Double(table[last + 2]), 0.45, accuracy: 5e-6)
        let white = ColorPipeline.apply(state, to: (1, 1, 1))
        assertColor(white, (0.9, 0.9, 0.45), accuracy: 5e-6)
    }

    func testToneTablesHonourTheRequestedSize() throws {
        let table = try XCTUnwrap(ColorPipeline.toneTables(try global(["contrast": 30]), size: 16))
        XCTAssertEqual(table.count, 48)
        XCTAssertEqual(table[0], 0)
        XCTAssertEqual(table[45], 1)
    }

    func testToneTableEntriesAreTheExactCalculationAtTheirInput() throws {
        let state = try edited(try global(["contrast": 25, "blacks": -20, "whites": 15, "dehaze": 10])) { state in
            try state.setCurve(channel: "rgb", points: [[0, 0.02], [0.5, 0.55], [1, 0.97]])
            try state.setCurve(channel: "red", points: [[0, 0], [0.4, 0.5], [1, 1]])
            try state.setCurve(channel: "green", points: [[0, 0.05], [1, 0.95]])
        }
        let basic = ColorPipeline.basicTone(state)
        let master = ColorPipeline.curve(state.curves["rgb"]!)
        let channels = ["red", "green", "blue"].map { ColorPipeline.curve(state.curves[$0]!) }
        let table = try XCTUnwrap(ColorPipeline.toneTables(state))
        for index in stride(from: 0, to: ColorPipeline.toneTableSize, by: 31) {
            let input = Double(index) / Double(ColorPipeline.toneTableSize - 1)
            let shared = master(basic(input))
            for channel in 0..<3 {
                XCTAssertEqual(Double(table[index * 3 + channel]), channels[channel](shared), accuracy: 1e-6, "entry \(index), channel \(channel)")
            }
        }
        for value in table {
            XCTAssertTrue(value.isFinite)
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThanOrEqual(value, 1)
        }
    }

    // MARK: Colour stage

    func testColourStageIsSkippedForAnUntouchedPhotoAndForToneOnlySettings() throws {
        XCTAssertNil(ColorPipeline.colorCube(base))
        XCTAssertNil(ColorPipeline.colorCube(try global(["contrast": 50, "exposureEV": 1, "temperature": 5000, "blacks": 10])))
        // A grading hue alone tints nothing: its strength is zero.
        XCTAssertNil(ColorPipeline.colorCube(try edited { try $0.setGrading(range: "shadows", settings: ["hue": 200]) }))
        XCTAssertNil(ColorPipeline.colorCube(try edited { try $0.configureGrading(["blending": 1, "balance": 0.5]) }))
    }

    func testEveryColourSettingSwitchesTheColourStageOn() throws {
        XCTAssertNotNil(ColorPipeline.colorCube(try global(["saturation": 1]), size: 3))
        XCTAssertNotNil(ColorPipeline.colorCube(try global(["vibrance": -1]), size: 3))
        XCTAssertNotNil(ColorPipeline.colorCube(try global(["dehaze": 5]), size: 3), "dehaze also restores colour")
        for color in Specs.colorRanges {
            for key in ["hue", "saturation", "luminance"] {
                let state = try edited { try $0.adjustHSL(color: .string(color), adjustments: .object([key: 5])) }
                XCTAssertNotNil(ColorPipeline.colorCube(state, size: 3), "\(color) \(key)")
            }
        }
        for range in Specs.gradingRanges {
            XCTAssertNotNil(ColorPipeline.colorCube(try edited { try $0.setGrading(range: .string(range), settings: ["saturation": 0.1]) }, size: 3), range)
            XCTAssertNotNil(ColorPipeline.colorCube(try edited { try $0.setGrading(range: .string(range), settings: ["luminance": -0.1]) }, size: 3), range)
        }
    }

    func testColourCubeIsRGBAWithRedVaryingFastest() throws {
        let cube = try XCTUnwrap(ColorPipeline.colorCube(try global(["saturation": -100])))
        let size = ColorPipeline.cubeSize
        XCTAssertEqual(cube.count, size * size * size * 4)
        XCTAssertEqual(cube.count, 143_748)

        // With saturation at −100 every entry is the luma of its own grid colour, which tells the axes apart.
        let step = 1.0 / 32
        func entry(_ red: Int, _ green: Int, _ blue: Int) -> [Float] {
            let offset = ((blue * size + green) * size + red) * 4
            return Array(cube[offset..<(offset + 4)])
        }
        XCTAssertEqual(entry(0, 0, 0), [0, 0, 0, 1])
        // The second entry is the next red step.
        XCTAssertEqual(Double(cube[4]), ColorPipeline.luma(step, 0, 0), accuracy: 5e-6)
        XCTAssertEqual(Double(cube[5]), ColorPipeline.luma(step, 0, 0), accuracy: 5e-6)
        XCTAssertEqual(Double(cube[6]), ColorPipeline.luma(step, 0, 0), accuracy: 5e-6)
        XCTAssertEqual(cube[7], 1)
        XCTAssertEqual(Double(entry(0, 1, 0)[0]), ColorPipeline.luma(0, step, 0), accuracy: 5e-6)
        XCTAssertEqual(Double(entry(0, 0, 1)[0]), ColorPipeline.luma(0, 0, step), accuracy: 5e-6)
        XCTAssertEqual(Double(entry(32, 0, 0)[1]), 0.229, accuracy: 5e-6)
        XCTAssertEqual(Double(entry(0, 32, 0)[2]), 0.6917, accuracy: 5e-6)
        XCTAssertEqual(Double(entry(0, 0, 32)[0]), 0.0793, accuracy: 5e-6)
        for (index, component) in entry(32, 32, 32).enumerated() { XCTAssertEqual(Double(component), 1, accuracy: 5e-6, "component \(index)") }
        for index in stride(from: 3, to: cube.count, by: 4) where cube[index] != 1 {
            XCTFail("alpha at \(index) is \(cube[index])")
            break
        }
    }

    func testColourCubeKeepsEveryValueInsideZeroToOneUnderExtremeSettings() throws {
        for sign in [1.0, -1] {
            let state = try edited(try global(["saturation": 100, "vibrance": .number(100 * sign), "dehaze": .number(100 * sign)])) { state in
                for color in Specs.colorRanges {
                    try state.adjustHSL(color: .string(color), adjustments: ["hue": .number(100 * sign), "saturation": 100, "luminance": .number(100 * sign)])
                }
                try state.setGrading(range: "shadows", settings: ["hue": 220, "saturation": 1, "luminance": -1])
                try state.setGrading(range: "midtones", settings: ["hue": 120, "saturation": 1, "luminance": .number(sign)])
                try state.setGrading(range: "highlights", settings: ["hue": 40, "saturation": 1, "luminance": 1])
                try state.configureGrading(["blending": .number(sign > 0 ? 1 : 0), "balance": .number(sign)])
            }
            let cube = try XCTUnwrap(ColorPipeline.colorCube(state, size: 9))
            XCTAssertEqual(cube.count, 9 * 9 * 9 * 4)
            for value in cube {
                XCTAssertTrue(value.isFinite)
                XCTAssertGreaterThanOrEqual(value, 0)
                XCTAssertLessThanOrEqual(value, 1)
            }
        }
    }

    func testSaturationMinus100IsBlackAndWhiteAndKeepsBrightness() throws {
        let input: RGB = (0.8, 0.3, 0.2)
        let out = ColorPipeline.apply(try global(["saturation": -100]), to: input)
        XCTAssertEqual(out.0, out.1, accuracy: 5e-7)
        XCTAssertEqual(out.1, out.2, accuracy: 5e-7)
        XCTAssertEqual(out.0, luma(input), accuracy: 5e-7)
    }

    func testSaturationPlus100DoublesColourfulnessAndKeepsBrightness() throws {
        let input: RGB = (0.5, 0.4, 0.45)
        let out = ColorPipeline.apply(try global(["saturation": 100]), to: input)
        XCTAssertEqual(saturation(of: out), 2 * saturation(of: input), accuracy: 1e-9)
        XCTAssertEqual(luma(out), luma(input), accuracy: 1e-9)
    }

    func testSaturationAndVibranceNeverTouchGreys() throws {
        let state = try global(["saturation": 100, "vibrance": 100])
        assertColor(ColorPipeline.apply(state, to: (0.4, 0.4, 0.4)), (0.4, 0.4, 0.4))
        assertColor(ColorPipeline.apply(state, to: (0, 0, 0)), (0, 0, 0))
        assertColor(ColorPipeline.apply(state, to: (1, 1, 1)), (1, 1, 1), accuracy: 1e-12)
        assertColor(ColorPipeline.apply(try global(["saturation": -100, "vibrance": -100]), to: (0.4, 0.4, 0.4)), (0.4, 0.4, 0.4), accuracy: 1e-12)
    }

    func testVibranceLiftsMutedColoursMoreThanVividOnesAndGoesEasyOnSkin() throws {
        let state = try global(["vibrance": 60])
        func gain(_ input: RGB) -> Double { saturation(of: ColorPipeline.apply(state, to: input)) / saturation(of: input) }
        let muted: RGB = (0.45, 0.5, 0.6)
        let vivid: RGB = (0.1, 0.3, 0.9)
        XCTAssertGreaterThan(gain(muted), gain(vivid))
        XCTAssertGreaterThanOrEqual(gain(vivid), 1)
        let skin: RGB = (0.8, 0.6, 0.5)
        let sky: RGB = (0.5, 0.6, 0.8)
        XCTAssertGreaterThan(gain(sky), gain(skin))
        XCTAssertGreaterThan(gain(skin), 1)
    }

    func testNegativeVibranceMutesColoursWithoutRemovingThem() throws {
        let input: RGB = (0.45, 0.5, 0.6)
        let out = ColorPipeline.apply(try global(["vibrance": -100]), to: input)
        XCTAssertLessThan(saturation(of: out), saturation(of: input))
        XCTAssertGreaterThan(saturation(of: out), 0)
        XCTAssertEqual(luma(out), luma(input), accuracy: 1e-9)
    }

    func testHSLChangesItsOwnColourRangeAndLeavesTheOthersAlone() throws {
        let state = try edited { try $0.adjustHSL(color: "blue", adjustments: ["saturation": -100]) }
        let blue = ColorPipeline.apply(state, to: (0.15, 0.15, 0.9))
        XCTAssertLessThan(saturation(of: blue), 0.02)
        let red: RGB = (0.9, 0.15, 0.1)
        assertColor(ColorPipeline.apply(state, to: red), red)
        let grey: RGB = (0.5, 0.5, 0.5)
        assertColor(ColorPipeline.apply(state, to: grey), grey)
    }

    func testEachHSLRangeActsOnTheColourAtItsCentre() throws {
        // One fully saturated colour at the centre of each range, in the order of Specs.colorRanges.
        let centres: [RGB] = [(0.9, 0.1, 0.1), (0.9, 0.5, 0.1), (0.9, 0.9, 0.1), (0.1, 0.9, 0.1), (0.1, 0.9, 0.9), (0.1, 0.1, 0.9), (0.5, 0.1, 0.9), (0.9, 0.1, 0.9)]
        for (index, color) in Specs.colorRanges.enumerated() {
            let state = try edited { try $0.adjustHSL(color: .string(color), adjustments: ["saturation": -100]) }
            for (other, input) in centres.enumerated() {
                let remaining = saturation(of: ColorPipeline.apply(state, to: input)) / saturation(of: input)
                if other == index {
                    XCTAssertLessThan(remaining, 0.02, "\(color) should lose its own colour")
                } else {
                    XCTAssertEqual(remaining, 1, accuracy: 1e-9, "\(color) should leave \(Specs.colorRanges[other]) alone")
                }
            }
        }
    }

    func testHSLFadesBetweenNeighbouringRanges() throws {
        let state = try edited { try $0.adjustHSL(color: "blue", adjustments: ["saturation": -100]) }
        // Hue 210 is half way between aqua (180) and blue (240).
        let between: RGB = (0.1, 0.5, 0.9)
        let remaining = saturation(of: ColorPipeline.apply(state, to: between)) / saturation(of: between)
        XCTAssertGreaterThan(remaining, 0.3)
        XCTAssertLessThan(remaining, 0.7)
    }

    func testHSLFadesOutForColoursThatAreNearlyGrey() throws {
        let state = try edited { try $0.adjustHSL(color: "blue", adjustments: ["saturation": -100]) }
        let nearlyGrey: RGB = (0.5, 0.5, 0.51)
        assertColor(ColorPipeline.apply(state, to: nearlyGrey), nearlyGrey, accuracy: 1e-9)
    }

    func testHSLHueTurnsColoursTheExpectedWayAndKeepsTheirBrightness() throws {
        let red: RGB = (0.8, 0.2, 0.2)
        let towardsOrange = ColorPipeline.apply(try edited { try $0.adjustHSL(color: "red", adjustments: ["hue": 100]) }, to: red)
        XCTAssertGreaterThan(towardsOrange.1, towardsOrange.2 + 0.1)
        XCTAssertEqual(luma(towardsOrange), luma(red), accuracy: 0.0005)
        let towardsMagenta = ColorPipeline.apply(try edited { try $0.adjustHSL(color: "red", adjustments: ["hue": -100]) }, to: red)
        XCTAssertGreaterThan(towardsMagenta.2, towardsMagenta.1 + 0.1)
        XCTAssertEqual(luma(towardsMagenta), luma(red), accuracy: 0.0005)
    }

    func testHSLLuminanceDarkensAndBrightensAColour() throws {
        let blue: RGB = (0.2, 0.3, 0.8)
        let darker = ColorPipeline.apply(try edited { try $0.adjustHSL(color: "blue", adjustments: ["luminance": -50]) }, to: blue)
        XCTAssertLessThan(luma(darker), luma(blue) - 0.05)
        let brighter = ColorPipeline.apply(try edited { try $0.adjustHSL(color: "blue", adjustments: ["luminance": 50]) }, to: blue)
        XCTAssertGreaterThan(luma(brighter), luma(blue) + 0.03)
    }

    func testGradingTintsEachTonalRangeWithItsOwnHue() throws {
        let state = try edited { state in
            try state.setGrading(range: "shadows", settings: ["hue": 240, "saturation": 0.3])
            try state.setGrading(range: "highlights", settings: ["hue": 40, "saturation": 0.3])
        }
        let dark = ColorPipeline.apply(state, to: (0.1, 0.1, 0.1))
        XCTAssertGreaterThan(dark.2, dark.0)
        let bright = ColorPipeline.apply(state, to: (0.9, 0.9, 0.9))
        XCTAssertGreaterThan(bright.0, bright.2)
        // A tint adds colour, not brightness.
        XCTAssertEqual(luma(bright), 0.9, accuracy: 0.005)
        XCTAssertEqual(luma(dark), 0.1, accuracy: 0.005)
    }

    func testGradingMidtonesTintTheMiddleMoreThanTheEnds() throws {
        let state = try edited { try $0.setGrading(range: "midtones", settings: ["hue": 120, "saturation": 0.4]) }
        func greenness(_ level: Double) -> Double {
            let out = ColorPipeline.apply(state, to: (level, level, level))
            return out.1 - out.0
        }
        XCTAssertGreaterThan(greenness(0.5), greenness(0.05))
        XCTAssertGreaterThan(greenness(0.5), greenness(0.95))
        XCTAssertGreaterThan(greenness(0.5), 0.05)
    }

    func testGradingBalanceAndBlendingMoveTheSplitBetweenRanges() throws {
        let tinted = try edited { try $0.setGrading(range: "shadows", settings: ["hue": 240, "saturation": 0.5]) }
        func blueness(_ state: EditingState) -> Double {
            let out = ColorPipeline.apply(state, to: (0.5, 0.5, 0.5))
            return out.2 - out.0
        }
        func mixed(_ settings: JSONValue) throws -> EditingState { try edited(tinted) { try $0.configureGrading(settings) } }
        XCTAssertGreaterThan(blueness(try mixed(["balance": -0.8])), blueness(tinted))
        XCTAssertLessThan(blueness(try mixed(["balance": 0.8])), blueness(tinted))
        XCTAssertGreaterThan(blueness(try mixed(["blending": 1])), blueness(try mixed(["blending": 0])))
    }

    func testGradingLuminanceAloneLiftsOrLowersItsRange() throws {
        let lifted = try edited { try $0.setGrading(range: "shadows", settings: ["luminance": 0.5]) }
        XCTAssertGreaterThan(ColorPipeline.apply(lifted, to: (0.1, 0.1, 0.1)).0, 0.15)
        XCTAssertEqual(ColorPipeline.apply(lifted, to: (0.95, 0.95, 0.95)).0, 0.95, accuracy: 0.005)
        let lowered = try edited { try $0.setGrading(range: "highlights", settings: ["luminance": -0.5]) }
        XCTAssertLessThan(ColorPipeline.apply(lowered, to: (0.9, 0.9, 0.9)).0, 0.85)
        XCTAssertEqual(ColorPipeline.apply(lowered, to: (0.05, 0.05, 0.05)).0, 0.05, accuracy: 0.005)
        // Lifting adds no colour.
        let grey = ColorPipeline.apply(lifted, to: (0.1, 0.1, 0.1))
        XCTAssertEqual(grey.0, grey.1, accuracy: 1e-12)
        XCTAssertEqual(grey.1, grey.2, accuracy: 1e-12)
    }

    func testTheCubeAgreesWithTheExactCalculationAtItsGridPoints() throws {
        let state = try edited(try global(["saturation": 20, "vibrance": 30])) { state in
            try state.adjustHSL(color: "green", adjustments: ["hue": 40, "saturation": -30, "luminance": 10])
            try state.setGrading(range: "midtones", settings: ["hue": 100, "saturation": 0.2])
        }
        let size = 5
        let cube = try XCTUnwrap(ColorPipeline.colorCube(state, size: size))
        for blue in 0..<size {
            for green in 0..<size {
                for red in 0..<size {
                    let offset = ((blue * size + green) * size + red) * 4
                    let exact = ColorPipeline.apply(state, to: (Double(red) / 4, Double(green) / 4, Double(blue) / 4))
                    let stored: RGB = (Double(cube[offset]), Double(cube[offset + 1]), Double(cube[offset + 2]))
                    assertColor(stored, exact, accuracy: 5e-6)
                    XCTAssertEqual(cube[offset + 3], 1)
                }
            }
        }
    }

    func testApplyRunsTheToneStageBeforeTheColourStage() throws {
        // Contrast pushes this colour's channels apart; desaturating afterwards must use the toned values.
        let state = try global(["contrast": 40, "saturation": -100])
        let input: RGB = (0.7, 0.4, 0.2)
        let tone = ColorPipeline.basicTone(state)
        let expected = ColorPipeline.luma(tone(input.0), tone(input.1), tone(input.2))
        let out = ColorPipeline.apply(state, to: input)
        assertColor(out, (expected, expected, expected), accuracy: 1e-9)
    }

    func testApplyClampsItsInput() throws {
        let state = try global(["saturation": -100])
        assertColor(ColorPipeline.apply(state, to: (2, 2, 2)), (1, 1, 1), accuracy: 1e-12)
        assertColor(ColorPipeline.apply(state, to: (-1, -1, -1)), (0, 0, 0), accuracy: 1e-12)
        assertColor(ColorPipeline.apply(base, to: (1.5, -0.5, 0.5)), (1, 0, 0.5))
    }

    // MARK: Base curve

    func testBaseCurveKeepsTheLightAsMeasuredUpToTheKnee() {
        for x in stride(from: 0.0, through: ColorPipeline.baseCurveKnee, by: 0.01) {
            XCTAssertEqual(ColorPipeline.baseCurve(x), x, accuracy: 1e-12)
        }
        XCTAssertEqual(ColorPipeline.baseCurve(-0.1), 0, "negative light is black")
    }

    func testBaseCurveRollsOffHighlightsWithoutAJoint() {
        let knee = ColorPipeline.baseCurveKnee
        let h = 1e-6
        let slopeAbove = (ColorPipeline.baseCurve(knee + h) - ColorPipeline.baseCurve(knee)) / h
        XCTAssertEqual(slopeAbove, 1, accuracy: 1e-4, "the same slope on both sides of the knee")

        var previous = -1.0
        for step in 0...2000 {
            let y = ColorPipeline.baseCurve(Double(step) / 2000 * ColorPipeline.baseCurveMaximum)
            XCTAssertGreaterThanOrEqual(y, previous, "the curve never reverses tones")
            XCTAssertLessThanOrEqual(y, 1)
            previous = y
        }
        let white = ColorPipeline.baseCurve(1)
        XCTAssertGreaterThan(white, 0.88, "the decoder's white stays bright")
        XCTAssertLessThan(white, 0.95, "and leaves room for what is brighter")
        XCTAssertGreaterThan(ColorPipeline.baseCurve(ColorPipeline.baseCurveMaximum), 0.9999)
    }

    func testBaseCurveTableIsTheCurveInEncodedValues() {
        let size = ColorPipeline.baseCurveTableSize
        let table = ColorPipeline.baseCurveTable()
        XCTAssertEqual(table.count, size * 3)
        XCTAssertEqual(table[0], 0)
        XCTAssertEqual(Double(table[(size - 1) * 3]), 1, accuracy: 1e-4)
        for i in stride(from: 0, to: size, by: 37) {
            let encoded = Double(i) / Double(size - 1) * ColorPipeline.baseCurveDomain
            let expected = ColorPipeline.encode(ColorPipeline.baseCurve(ColorPipeline.decode(encoded)))
            for channel in 0..<3 { XCTAssertEqual(Double(table[i * 3 + channel]), expected, accuracy: 1e-5) }
            if ColorPipeline.decode(encoded) <= ColorPipeline.baseCurveKnee {
                XCTAssertEqual(Double(table[i * 3]), encoded, accuracy: 1e-5, "the identity below the knee")
            }
        }
        // Even steps in encoded values stay fine in the shadows.
        let firstSteps = ColorPipeline.decode(ColorPipeline.baseCurveDomain / Double(size - 1))
        XCTAssertLessThan(firstSteps, 0.0002)
    }

    func testTransferFunctionRoundTrips() {
        for x in [0, 0.001, 0.0031308, 0.01, 0.18, 0.5, 1, 2, 8] {
            XCTAssertEqual(ColorPipeline.decode(ColorPipeline.encode(x)), x, accuracy: 1e-9)
        }
        XCTAssertEqual(ColorPipeline.encode(0.18), 0.4614, accuracy: 1e-3)
    }
}
