import Foundation
import XCTest

@testable import OscuruCore

final class EditingStateTests: XCTestCase {
    private let zero = ["hue": 0.0, "saturation": 0.0, "luminance": 0.0]
    private let identity: [[Double]] = [[0, 0], [1, 1]]
    private let globalNames = "exposureEV, contrast, highlights, shadows, whites, blacks, temperature, tint, texture, clarity, dehaze, vibrance, saturation, vignette"

    /// A state with something changed in every section.
    private func richState() throws -> EditingState {
        try edited(EditingState(defaults: PhotoDefaults(temperature: 4800, tint: -3, sharpening: 40))) { state in
            try state.adjust(["contrast": 12, "vibrance": 15, "exposureEV": -0.35])
            try state.setCurve(channel: "rgb", points: [[0, 0.03], [0.5, 0.5], [1, 0.98]])
            try state.setCurve(channel: "blue", points: [[0, 0.1], [1, 1]])
            try state.adjustHSL(color: "orange", adjustments: ["saturation": 5, "luminance": 8])
            try state.setGrading(range: "highlights", settings: ["hue": 42, "saturation": 0.08])
            try state.configureGrading(["balance": -0.25])
            try state.setDetail(["noiseReduction": 25])
            try state.setCrop(["angle": 2.5, "y": 0.1, "height": 0.8, "rotation": 90, "flipHorizontal": true])
        }
    }

    // MARK: Specs

    func testSpecsListTheSettingsTheEditorHas() {
        XCTAssertEqual(Specs.global.map(\.name).joined(separator: ", "), globalNames)
        XCTAssertEqual(Specs.hsl.map(\.name), ["hue", "saturation", "luminance"])
        XCTAssertEqual(Specs.grading.map(\.name), ["hue", "saturation", "luminance"])
        XCTAssertEqual(Specs.gradingMix.map(\.name), ["blending", "balance"])
        XCTAssertEqual(Specs.detail.map(\.name), ["sharpening", "noiseReduction", "colorNoiseReduction"])
        XCTAssertEqual(Specs.colorRanges, ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"])
        XCTAssertEqual(Specs.curveChannels, ["rgb", "red", "green", "blue"])
        XCTAssertEqual(Specs.gradingRanges, ["shadows", "midtones", "highlights"])
        XCTAssertEqual(Specs.resetSections, ["all", "light", "color", "curves", "hsl", "grading", "detail", "crop"])
    }

    func testEverySpecHasADefaultInsideItsRangeAndADescription() {
        for spec in Specs.global + Specs.hsl + Specs.grading + Specs.gradingMix + Specs.detail + [Specs.cropAngle] {
            XCTAssertLessThan(spec.min, spec.max, spec.name)
            XCTAssertGreaterThanOrEqual(spec.defaultValue, spec.min, spec.name)
            XCTAssertLessThanOrEqual(spec.defaultValue, spec.max, spec.name)
            XCTAssertFalse(spec.description.isEmpty, spec.name)
        }
    }

    func testEveryGlobalSettingBelongsToExactlyOneResetSection() {
        let grouped = Specs.lightKeys + Specs.colorKeys + Specs.effectKeys
        XCTAssertEqual(grouped.sorted(), Specs.global.map(\.name).sorted())
    }

    // MARK: Defaults

    func testAnUntouchedStateHasEverySettingAtItsDefault() {
        let state = EditingState()
        XCTAssertEqual(Set(state.global.keys), Set(Specs.global.map(\.name)))
        for spec in Specs.global { XCTAssertEqual(state.global[spec.name], spec.defaultValue, spec.name) }
        XCTAssertEqual(state.value("temperature"), 6500)
        XCTAssertEqual(state.value("exposureEV"), 0)

        XCTAssertEqual(Set(state.curves.keys), Set(Specs.curveChannels))
        for channel in Specs.curveChannels {
            XCTAssertEqual(state.curves[channel], identity, channel)
            XCTAssertTrue(state.isIdentityCurve(channel), channel)
        }

        XCTAssertEqual(Set(state.hsl.keys), Set(Specs.colorRanges))
        for color in Specs.colorRanges { XCTAssertEqual(state.hsl[color], zero, color) }

        XCTAssertEqual(state.grading, Grading(shadows: zero, midtones: zero, highlights: zero, blending: 0.5, balance: 0))
        XCTAssertEqual(state.detail, ["sharpening": 0, "noiseReduction": 0, "colorNoiseReduction": 0])
        XCTAssertEqual(state.crop, Crop())
        XCTAssertEqual(state.crop.width, 1)
        XCTAssertEqual(state.crop.height, 1)
        XCTAssertEqual(state.crop.rotation, 0)
        XCTAssertFalse(state.crop.flipHorizontal)
    }

    func testStartsFromThePhotoNotFromAGenericWhiteBalance() {
        let state = EditingState(defaults: PhotoDefaults(temperature: 5234.6, tint: 11.2, sharpening: 39.5, noiseReduction: 42.4, colorNoiseReduction: 50))
        XCTAssertEqual(state.value("temperature"), 5235)
        XCTAssertEqual(state.value("tint"), 11)
        XCTAssertEqual(state.detail["sharpening"], 40)
        XCTAssertEqual(state.detail["noiseReduction"], 42)
        XCTAssertEqual(state.detail["colorNoiseReduction"], 50)
        XCTAssertEqual(state.value("exposureEV"), 0)
        XCTAssertEqual(state.curves["rgb"], identity)
    }

    func testPhotoDefaultsOutsideTheRangeAreClamped() {
        let low = EditingState(defaults: PhotoDefaults(temperature: 1200, tint: -400, sharpening: -5, noiseReduction: -1, colorNoiseReduction: -0.6))
        XCTAssertEqual(low.value("temperature"), 2000)
        XCTAssertEqual(low.value("tint"), -150)
        XCTAssertEqual(low.detail, ["sharpening": 0, "noiseReduction": 0, "colorNoiseReduction": 0])

        let high = EditingState(defaults: PhotoDefaults(temperature: 90000, tint: 400, sharpening: 150, noiseReduction: 100.4, colorNoiseReduction: 1e9))
        XCTAssertEqual(high.value("temperature"), 25000)
        XCTAssertEqual(high.value("tint"), 150)
        XCTAssertEqual(high.detail, ["sharpening": 100, "noiseReduction": 100, "colorNoiseReduction": 100])
    }

    func testPhotoDefaultsThatAreNotFiniteFallBackToTheGenericDefault() {
        let state = EditingState(defaults: PhotoDefaults(temperature: .nan, tint: .infinity, sharpening: -.infinity, noiseReduction: .nan, colorNoiseReduction: .nan))
        XCTAssertEqual(state, EditingState())
    }

    func testValueOfAnUnknownSettingIsZero() {
        XCTAssertEqual(EditingState().value("sharpenRadius"), 0)
    }

    // MARK: adjust

    func testAdjustSetsOnlyTheSettingsGiven() throws {
        let before = EditingState()
        var after = before
        try after.adjust(["exposureEV": 0.35, "highlights": -40])
        XCTAssertEqual(after.value("exposureEV"), 0.35)
        XCTAssertEqual(after.value("highlights"), -40)
        XCTAssertEqual(after.value("shadows"), 0)
        XCTAssertEqual(after.value("temperature"), 6500)
        XCTAssertEqual(before.value("exposureEV"), 0, "the copy it was made from is untouched")

        try after.adjust(["shadows": 20])
        XCTAssertEqual(after.value("exposureEV"), 0.35, "a later call keeps earlier values")
        XCTAssertEqual(after.value("shadows"), 20)
        try after.adjust([:])
        XCTAssertEqual(after.value("shadows"), 20)
    }

    func testAdjustAcceptsEverySettingAtBothEndsOfItsRange() throws {
        var state = EditingState()
        for spec in Specs.global {
            try state.adjust(.object([spec.name: .number(spec.min)]))
            XCTAssertEqual(state.value(spec.name), spec.min, spec.name)
            try state.adjust(.object([spec.name: .number(spec.max)]))
            XCTAssertEqual(state.value(spec.name), spec.max, spec.name)
        }
    }

    func testAdjustRejectsValuesOutsideTheRangeNamingTheSettingAndItsRange() {
        var state = EditingState()
        assertStateError(try state.adjust(["exposureEV": 9]), "adjust.exposureEV must be between -5 and 5, got 9")
        assertStateError(try state.adjust(["exposureEV": -5.01]), "adjust.exposureEV must be between -5 and 5, got -5.01")
        assertStateError(try state.adjust(["tint": 999]), "adjust.tint must be between -150 and 150, got 999")
        assertStateError(try state.adjust(["temperature": 1999]), "adjust.temperature must be between 2000 and 25000, got 1999")
        assertStateError(try state.adjust(["contrast": 100.5]), "adjust.contrast must be between -100 and 100, got 100.5")
        for spec in Specs.global {
            assertStateError(try state.adjust(.object([spec.name: .number(spec.max + 1)])), contains: "adjust.\(spec.name) must be between")
            assertStateError(try state.adjust(.object([spec.name: .number(spec.min - 1)])), contains: "adjust.\(spec.name) must be between")
        }
        XCTAssertEqual(state, EditingState())
    }

    func testAdjustRejectsValuesThatAreNotFiniteNumbers() {
        var state = EditingState()
        assertStateError(try state.adjust(["contrast": "10"]), "adjust.contrast must be a finite number, got \"10\"")
        assertStateError(try state.adjust(["contrast": true]), "adjust.contrast must be a finite number, got true")
        assertStateError(try state.adjust(["contrast": nil]), "adjust.contrast must be a finite number, got null")
        assertStateError(try state.adjust(["contrast": [10]]), "adjust.contrast must be a finite number, got an array")
        assertStateError(try state.adjust(["contrast": ["value": 10]]), "adjust.contrast must be a finite number, got an object")
        assertStateError(try state.adjust(["contrast": .number(.nan)]), "adjust.contrast must be a finite number, got NaN")
        assertStateError(try state.adjust(["contrast": .number(.infinity)]), "adjust.contrast must be a finite number, got Infinity")
        assertStateError(try state.adjust(["contrast": .number(-.infinity)]), "adjust.contrast must be a finite number, got -Infinity")
        XCTAssertEqual(state, EditingState())
    }

    func testAdjustRejectsAnUnknownSettingAndNamesTheValidOnes() {
        var state = EditingState()
        assertStateError(try state.adjust(["exposure": 1]), "adjust has no setting \"exposure\". Valid settings: \(globalNames)")
        assertStateError(try state.adjust(["sharpenRadius": 1]), contains: "no setting \"sharpenRadius\"")
        // With several unknown names, the first in alphabetical order is the one reported.
        assertStateError(try state.adjust(["zeta": 1, "alpha": 2]), contains: "no setting \"alpha\"")
    }

    func testAdjustRejectsAnythingThatIsNotAnObject() {
        var state = EditingState()
        assertStateError(try state.adjust(5), "adjust must be an object, got 5")
        assertStateError(try state.adjust("brighter"), "adjust must be an object, got \"brighter\"")
        assertStateError(try state.adjust([1, 2]), "adjust must be an object, got an array")
        assertStateError(try state.adjust(nil), "adjust must be an object, got null")
    }

    func testAFailedAdjustChangesNothing() {
        var state = EditingState()
        assertStateError(try state.adjust(["exposureEV": 1, "contrast": 999]), contains: "adjust.contrast")
        assertStateError(try state.adjust(["exposureEV": 1, "unknown": 0]), contains: "no setting \"unknown\"")
        XCTAssertEqual(state, EditingState())
    }

    // MARK: Curves

    func testSetCurveReplacesOneChannelAndSortsItsPoints() throws {
        var state = EditingState()
        try state.setCurve(channel: "rgb", points: [[1, 0.98], [0, 0.03], [0.5, 0.5]])
        XCTAssertEqual(state.curves["rgb"], [[0, 0.03], [0.5, 0.5], [1, 0.98]])
        XCTAssertEqual(state.curves["red"], identity)
        XCTAssertFalse(state.isIdentityCurve("rgb"))
        XCTAssertTrue(state.isIdentityCurve("red"))

        try state.setCurve(channel: "rgb", points: [[0.2, 0.2], [0.8, 0.8]])
        XCTAssertEqual(state.curves["rgb"], [[0.2, 0.2], [0.8, 0.8]], "a curve is replaced whole, not merged")
        XCTAssertTrue(state.isIdentityCurve("rgb"), "points on the diagonal change nothing")

        for channel in Specs.curveChannels {
            try state.setCurve(channel: .string(channel), points: [[0, 0.1], [1, 0.9]])
            XCTAssertEqual(state.curves[channel], [[0, 0.1], [1, 0.9]], channel)
        }
    }

    func testSetCurveRejectsAnUnknownChannel() {
        var state = EditingState()
        assertStateError(
            try state.setCurve(channel: "luma", points: [[0, 0], [1, 1]]),
            "curve channel must be one of \"rgb\", \"red\", \"green\", \"blue\", got \"luma\"")
        assertStateError(try state.setCurve(channel: 1, points: [[0, 0], [1, 1]]), contains: "curve channel must be one of", "got 1")
        assertStateError(try state.setCurve(channel: "red", points: [[0, 0]]), contains: "curves.red needs between 2 and 16 points")
        XCTAssertEqual(state, EditingState())
    }

    func testNormalizeCurveSortsPointsByInput() throws {
        XCTAssertEqual(try EditingState.normalizeCurve("c", [[1, 0.9], [0, 0.1], [0.5, 0.5]]), [[0, 0.1], [0.5, 0.5], [1, 0.9]])
        // Outputs may go down: only the inputs are ordered.
        XCTAssertEqual(try EditingState.normalizeCurve("c", [[1, 0], [0, 1]]), [[0, 1], [1, 0]])
    }

    func testNormalizeCurveAcceptsTwoToSixteenPoints() throws {
        XCTAssertEqual(try EditingState.normalizeCurve("c", [[0.2, 0.3], [0.9, 0.4]]).count, 2)
        let sixteen = JSONValue.array((0..<16).map { [.number(Double($0) / 15), .number(Double($0) / 15)] })
        XCTAssertEqual(try EditingState.normalizeCurve("c", sixteen).count, 16)

        assertStateError(try EditingState.normalizeCurve("c", []), "c needs between 2 and 16 points, got 0")
        assertStateError(try EditingState.normalizeCurve("c", [[0, 0]]), "c needs between 2 and 16 points, got 1")
        let seventeen = JSONValue.array((0..<17).map { [.number(Double($0) / 16), .number(Double($0) / 16)] })
        assertStateError(try EditingState.normalizeCurve("c", seventeen), "c needs between 2 and 16 points, got 17")
    }

    func testNormalizeCurveRejectsAnythingThatIsNotAListOfPairs() {
        assertStateError(try EditingState.normalizeCurve("c", "s-curve"), "c must be an array of [input, output] points")
        assertStateError(try EditingState.normalizeCurve("c", ["points": []]), "c must be an array of [input, output] points")
        assertStateError(try EditingState.normalizeCurve("c", [[0, 0], [1]]), "c[1] must be an [input, output] pair")
        assertStateError(try EditingState.normalizeCurve("c", [[0, 0, 0], [1, 1]]), "c[0] must be an [input, output] pair")
        assertStateError(try EditingState.normalizeCurve("c", [[0, 0], 1]), "c[1] must be an [input, output] pair")
        assertStateError(try EditingState.normalizeCurve("c", [[0, 0], ["x": 1, "y": 1]]), "c[1] must be an [input, output] pair")
    }

    func testNormalizeCurveRejectsCoordinatesOutsideZeroToOne() {
        assertStateError(try EditingState.normalizeCurve("c", [[0, 0], [0.5, 1.2]]), "c[1][1] must be between 0 and 1, got 1.2")
        assertStateError(try EditingState.normalizeCurve("c", [[-0.1, 0], [1, 1]]), "c[0][0] must be between 0 and 1, got -0.1")
        assertStateError(try EditingState.normalizeCurve("c", [[0, 0], [255, 1]]), "c[1][0] must be between 0 and 1, got 255")
        assertStateError(try EditingState.normalizeCurve("c", [[0, "0"], [1, 1]]), "c[0][1] must be a finite number, got \"0\"")
        assertStateError(try EditingState.normalizeCurve("c", [[0, 0], [.number(.nan), 1]]), contains: "c[1][0] must be a finite number")
    }

    func testNormalizeCurveRejectsPointsWithTheSameOrNearlyTheSameInput() throws {
        assertStateError(
            try EditingState.normalizeCurve("c", [[0.5, 0], [0.5, 1]]),
            "c has two points with (almost) the same input 0.5; inputs must differ by at least 0.004")
        // Found after sorting, wherever the two points were in the list.
        assertStateError(try EditingState.normalizeCurve("c", [[0.503, 1], [0, 0], [0.5, 0.4]]), contains: "(almost) the same input 0.503")
        assertStateError(try EditingState.normalizeCurve("c", [[0, 0], [0.003, 1]]), contains: "(almost) the same input")
        XCTAssertEqual(try EditingState.normalizeCurve("c", [[0.5, 0.4], [0.505, 0.6]]), [[0.5, 0.4], [0.505, 0.6]])
    }

    func testIsIdentityCurveToleratesRoundingNoise() throws {
        let state = try edited { try $0.setCurve(channel: "green", points: [[0, 0.0000001], [0.5, 0.5], [1, 1]]) }
        XCTAssertTrue(state.isIdentityCurve("green"))
        XCTAssertFalse(try edited { try $0.setCurve(channel: "green", points: [[0, 0.001], [1, 1]]) }.isIdentityCurve("green"))
    }

    // MARK: HSL

    func testAdjustHSLMergesIntoOneColourRange() throws {
        var state = EditingState()
        try state.adjustHSL(color: "blue", adjustments: ["saturation": -15])
        try state.adjustHSL(color: "blue", adjustments: ["luminance": -10])
        XCTAssertEqual(state.hsl["blue"], ["hue": 0, "saturation": -15, "luminance": -10])
        XCTAssertEqual(state.hsl["blue"]?["saturation"], -15)
        for color in Specs.colorRanges where color != "blue" { XCTAssertEqual(state.hsl[color], zero, color) }

        for color in Specs.colorRanges {
            try state.adjustHSL(color: .string(color), adjustments: ["hue": 100, "saturation": -100, "luminance": 100])
            XCTAssertEqual(state.hsl[color], ["hue": 100, "saturation": -100, "luminance": 100], color)
        }
    }

    func testAdjustHSLRejectsUnknownColoursAndBadValues() {
        var state = EditingState()
        assertStateError(
            try state.adjustHSL(color: "teal", adjustments: ["hue": 1]),
            "hsl colour must be one of \"red\", \"orange\", \"yellow\", \"green\", \"aqua\", \"blue\", \"purple\", \"magenta\", got \"teal\"")
        assertStateError(try state.adjustHSL(color: nil, adjustments: ["hue": 1]), contains: "hsl colour must be one of", "got null")
        assertStateError(try state.adjustHSL(color: "blue", adjustments: ["hue": 101]), "hsl.blue.hue must be between -100 and 100, got 101")
        assertStateError(try state.adjustHSL(color: "blue", adjustments: ["saturation": "low"]), "hsl.blue.saturation must be a finite number, got \"low\"")
        assertStateError(
            try state.adjustHSL(color: "red", adjustments: ["lightness": 5]), "hsl.red has no setting \"lightness\". Valid settings: hue, saturation, luminance")
        assertStateError(try state.adjustHSL(color: "red", adjustments: 5), "hsl.red must be an object, got 5")
        assertStateError(try state.adjustHSL(color: "red", adjustments: ["hue": 10, "luminance": 500]), contains: "hsl.red.luminance")
        XCTAssertEqual(state, EditingState())
    }

    // MARK: Grading

    func testSetGradingMergesIntoOneTonalRange() throws {
        var state = EditingState()
        try state.setGrading(range: "shadows", settings: ["hue": 215, "saturation": 0.12])
        XCTAssertEqual(state.grading.shadows, ["hue": 215, "saturation": 0.12, "luminance": 0])
        XCTAssertEqual(state.grading.shadows["hue"], 215)
        try state.setGrading(range: "shadows", settings: ["luminance": -0.2])
        XCTAssertEqual(state.grading.shadows, ["hue": 215, "saturation": 0.12, "luminance": -0.2])
        XCTAssertEqual(state.grading.midtones, zero)
        XCTAssertEqual(state.grading.highlights, zero)

        try state.setGrading(range: "midtones", settings: ["hue": 360, "saturation": 1, "luminance": 1])
        try state.setGrading(range: "highlights", settings: ["hue": 0, "saturation": 0, "luminance": -1])
        XCTAssertEqual(state.grading["midtones"], ["hue": 360, "saturation": 1, "luminance": 1])
        XCTAssertEqual(state.grading["highlights"], ["hue": 0, "saturation": 0, "luminance": -1])
        XCTAssertEqual(state.grading["shadows"], state.grading.shadows)
        XCTAssertEqual(state.grading.blending, 0.5)
        XCTAssertEqual(state.grading.balance, 0)
    }

    func testSetGradingRejectsUnknownRangesAndBadValues() {
        var state = EditingState()
        assertStateError(
            try state.setGrading(range: "darks", settings: ["hue": 1]),
            "grading range must be one of \"shadows\", \"midtones\", \"highlights\", got \"darks\"")
        assertStateError(
            try state.setGrading(range: "shadows", settings: ["saturation": 12]), "grading.shadows.saturation must be between 0 and 1, got 12")
        assertStateError(try state.setGrading(range: "shadows", settings: ["hue": -10]), "grading.shadows.hue must be between 0 and 360, got -10")
        assertStateError(
            try state.setGrading(range: "highlights", settings: ["luminance": 1.5]), "grading.highlights.luminance must be between -1 and 1, got 1.5")
        assertStateError(
            try state.setGrading(range: "midtones", settings: ["balance": 0.2]),
            "grading.midtones has no setting \"balance\". Valid settings: hue, saturation, luminance")
        assertStateError(try state.setGrading(range: "midtones", settings: [0.1]), "grading.midtones must be an object, got an array")
        XCTAssertEqual(state, EditingState())
    }

    func testConfigureGradingSetsBlendingAndBalanceIndependently() throws {
        var state = EditingState()
        try state.configureGrading(["balance": -0.2])
        XCTAssertEqual(state.grading.balance, -0.2)
        XCTAssertEqual(state.grading.blending, 0.5)
        try state.configureGrading(["blending": 1])
        XCTAssertEqual(state.grading.balance, -0.2)
        XCTAssertEqual(state.grading.blending, 1)
        try state.configureGrading(["blending": 0, "balance": 1])
        XCTAssertEqual(state.grading.blending, 0)
        XCTAssertEqual(state.grading.balance, 1)
    }

    func testConfigureGradingRejectsBadValues() {
        var state = EditingState()
        assertStateError(try state.configureGrading(["blending": 1.5]), "grading.blending must be between 0 and 1, got 1.5")
        assertStateError(try state.configureGrading(["balance": -2]), "grading.balance must be between -1 and 1, got -2")
        assertStateError(try state.configureGrading(["hue": 10]), "grading has no setting \"hue\". Valid settings: blending, balance")
        assertStateError(try state.configureGrading(["balance": false]), "grading.balance must be a finite number, got false")
        assertStateError(try state.configureGrading("wide"), "grading must be an object, got \"wide\"")
        XCTAssertEqual(state, EditingState())
    }

    // MARK: Detail

    func testSetDetailSetsOnlyTheSettingsGiven() throws {
        var state = EditingState(defaults: PhotoDefaults(sharpening: 40, noiseReduction: 50, colorNoiseReduction: 50))
        try state.setDetail(["sharpening": 30])
        XCTAssertEqual(state.detail, ["sharpening": 30, "noiseReduction": 50, "colorNoiseReduction": 50])
        try state.setDetail(["noiseReduction": 0, "colorNoiseReduction": 100])
        XCTAssertEqual(state.detail, ["sharpening": 30, "noiseReduction": 0, "colorNoiseReduction": 100])
    }

    func testSetDetailRejectsBadValuesAndHasNoSharpenRadius() {
        var state = EditingState()
        assertStateError(try state.setDetail(["sharpening": -1]), "detail.sharpening must be between 0 and 100, got -1")
        assertStateError(try state.setDetail(["noiseReduction": 101]), "detail.noiseReduction must be between 0 and 100, got 101")
        assertStateError(try state.setDetail(["colorNoiseReduction": "high"]), "detail.colorNoiseReduction must be a finite number, got \"high\"")
        assertStateError(
            try state.setDetail(["sharpenRadius": 1]),
            "detail has no setting \"sharpenRadius\". Valid settings: sharpening, noiseReduction, colorNoiseReduction")
        assertStateError(try state.setDetail(40), "detail must be an object, got 40")
        XCTAssertEqual(state, EditingState())
    }

    // MARK: Crop

    func testSetCropMergesWithTheCurrentCrop() throws {
        var state = EditingState()
        try state.setCrop(["x": 0.1, "width": 0.8, "rotation": 90, "flipHorizontal": true])
        XCTAssertEqual(state.crop.x, 0.1)
        XCTAssertEqual(state.crop.y, 0)
        XCTAssertEqual(state.crop.width, 0.8)
        XCTAssertEqual(state.crop.height, 1)
        XCTAssertEqual(state.crop.rotation, 90)
        XCTAssertTrue(state.crop.flipHorizontal)
        XCTAssertFalse(state.crop.flipVertical)

        try state.setCrop(["angle": -3.5, "flipVertical": true, "flipHorizontal": false])
        XCTAssertEqual(state.crop.x, 0.1, "values left out keep their value")
        XCTAssertEqual(state.crop.width, 0.8)
        XCTAssertEqual(state.crop.angle, -3.5)
        XCTAssertEqual(state.crop.rotation, 90)
        XCTAssertFalse(state.crop.flipHorizontal)
        XCTAssertTrue(state.crop.flipVertical)
    }

    func testSetCropAcceptsARectangleThatExactlyFillsTheFrame() throws {
        var state = EditingState()
        try state.setCrop(["x": 0.2, "y": 0.5, "width": 0.8, "height": 0.5])
        XCTAssertEqual(state.crop.x + state.crop.width, 1, accuracy: 1e-9)
        try state.setCrop(["x": 0.95, "y": 0.95, "width": 0.05, "height": 0.05])
        XCTAssertEqual(state.crop.width, 0.05)
        // Sums that miss 1 only by floating-point rounding are accepted.
        try state.setCrop(["x": 0.1, "y": 0.7, "width": 0.9, "height": 0.3])
        try state.setCrop(["x": 0, "y": 0, "width": 1, "height": 1])
        XCTAssertEqual(state.crop, Crop())
    }

    func testSetCropKeepsTheRectangleInsideTheFrame() {
        var state = EditingState()
        assertStateError(
            try state.setCrop(["x": 0.5, "width": 0.8]),
            "crop rectangle leaves the frame: x + width and y + height must be at most 1 (got x 0.5, width 0.8, y 0, height 1)")
        assertStateError(try state.setCrop(["y": 0.3, "height": 0.75]), contains: "crop rectangle leaves the frame", "y 0.3, height 0.75")
        // Moving the corner alone also counts: the current width is still 1.
        assertStateError(try state.setCrop(["x": 0.1]), contains: "crop rectangle leaves the frame")
        XCTAssertEqual(state.crop, Crop())
    }

    func testSetCropChecksTheRectangleAgainstTheCurrentCrop() throws {
        var state = try edited { try $0.setCrop(["x": 0.4, "width": 0.5]) }
        assertStateError(try state.setCrop(["width": 0.7]), contains: "crop rectangle leaves the frame")
        XCTAssertEqual(state.crop.width, 0.5)
        try state.setCrop(["x": 0.3, "width": 0.7])
        XCTAssertEqual(state.crop.width, 0.7)
    }

    func testSetCropRejectsARectangleThatIsTooSmallOrOutsideTheUnitRange() {
        var state = EditingState()
        assertStateError(try state.setCrop(["width": 0.01]), "crop.width must be between 0.05 and 1, got 0.01")
        assertStateError(try state.setCrop(["height": 0]), "crop.height must be between 0.05 and 1, got 0")
        assertStateError(try state.setCrop(["width": 1.2]), "crop.width must be between 0.05 and 1, got 1.2")
        assertStateError(try state.setCrop(["x": -0.1]), "crop.x must be between 0 and 1, got -0.1")
        assertStateError(try state.setCrop(["y": 1.5]), "crop.y must be between 0 and 1, got 1.5")
        assertStateError(try state.setCrop(["x": "left"]), "crop.x must be a finite number, got \"left\"")
        XCTAssertEqual(state.crop, Crop())
    }

    func testSetCropAcceptsOnlyQuarterTurns() throws {
        var state = EditingState()
        for turn in [90, 180, 270, 0] {
            try state.setCrop(["rotation": .number(Double(turn))])
            XCTAssertEqual(state.crop.rotation, turn)
        }
        assertStateError(try state.setCrop(["rotation": 45]), "crop.rotation must be 0, 90, 180 or 270, got 45")
        assertStateError(try state.setCrop(["rotation": 360]), "crop.rotation must be 0, 90, 180 or 270, got 360")
        assertStateError(try state.setCrop(["rotation": -90]), "crop.rotation must be 0, 90, 180 or 270, got -90")
        assertStateError(try state.setCrop(["rotation": "90"]), "crop.rotation must be 0, 90, 180 or 270, got \"90\"")
        assertStateError(try state.setCrop(["rotation": .number(.nan)]), contains: "crop.rotation must be 0, 90, 180 or 270")
    }

    func testSetCropLimitsTheStraightenAngle() throws {
        var state = EditingState()
        try state.setCrop(["angle": 45])
        XCTAssertEqual(state.crop.angle, 45)
        try state.setCrop(["angle": -45])
        XCTAssertEqual(state.crop.angle, -45)
        assertStateError(try state.setCrop(["angle": 50]), "crop.angle must be between -45 and 45, got 50")
        assertStateError(try state.setCrop(["angle": -45.5]), "crop.angle must be between -45 and 45, got -45.5")
    }

    func testSetCropFlipsMustBeBooleans() {
        var state = EditingState()
        assertStateError(try state.setCrop(["flipVertical": "yes"]), "crop.flipVertical must be true or false, got \"yes\"")
        assertStateError(try state.setCrop(["flipHorizontal": 1]), "crop.flipHorizontal must be true or false, got 1")
        assertStateError(try state.setCrop(["flipHorizontal": nil]), "crop.flipHorizontal must be true or false, got null")
    }

    func testSetCropRejectsUnknownSettingsAndValuesThatAreNotObjects() {
        var state = EditingState()
        assertStateError(
            try state.setCrop(["zoom": 2]),
            "crop has no setting \"zoom\". Valid settings: x, y, width, height, angle, rotation, flipHorizontal, flipVertical")
        assertStateError(try state.setCrop("square"), "crop must be an object, got \"square\"")
    }

    func testAFailedCropChangesNothing() {
        var state = EditingState()
        assertStateError(try state.setCrop(["x": 0.2, "width": 0.5, "angle": 10, "rotation": 45]), contains: "crop.rotation")
        assertStateError(try state.setCrop(["angle": 10, "flipVertical": true, "x": 0.5]), contains: "leaves the frame")
        XCTAssertEqual(state.crop, Crop())
    }

    // MARK: Reset

    func testResetPutsOneSectionBackToThePhotoAsOpened() throws {
        let defaults = PhotoDefaults(temperature: 5200, tint: 8, sharpening: 40, noiseReduction: 50, colorNoiseReduction: 50)
        let fresh = EditingState(defaults: defaults)
        let state = try edited(fresh) { state in
            try state.adjust([
                "exposureEV": 1, "contrast": 10, "highlights": -20, "shadows": 20, "whites": 5, "blacks": -5,
                "temperature": 7000, "tint": -4, "vibrance": 12, "saturation": -8,
                "texture": 15, "clarity": 20, "dehaze": 25, "vignette": -30,
            ])
            try state.setCurve(channel: "red", points: [[0, 0.1], [1, 1]])
            try state.adjustHSL(color: "green", adjustments: ["hue": 10])
            try state.setGrading(range: "midtones", settings: ["hue": 100, "saturation": 0.2])
            try state.configureGrading(["blending": 0.8, "balance": 0.3])
            try state.setDetail(["sharpening": 70, "noiseReduction": 10])
            try state.setCrop(["x": 0.1, "width": 0.5, "angle": 3, "rotation": 180, "flipVertical": true])
        }
        func reset(_ section: JSONValue) throws -> EditingState {
            try edited(state) { try $0.reset(section: section, defaults: defaults) }
        }
        func expected(_ change: (inout EditingState) -> Void) -> EditingState {
            var result = state
            change(&result)
            return result
        }

        XCTAssertEqual(
            try reset("light"),
            expected { for key in ["exposureEV", "contrast", "highlights", "shadows", "whites", "blacks"] { $0.global[key] = 0 } })
        XCTAssertEqual(
            try reset("color"),
            expected {
                $0.global["temperature"] = 5200
                $0.global["tint"] = 8
                $0.global["vibrance"] = 0
                $0.global["saturation"] = 0
            })
        XCTAssertEqual(try reset("curves"), expected { $0.curves = fresh.curves })
        XCTAssertEqual(try reset("hsl"), expected { $0.hsl = fresh.hsl })
        XCTAssertEqual(try reset("grading"), expected { $0.grading = fresh.grading })
        XCTAssertEqual(
            try reset("detail"),
            expected {
                $0.detail = ["sharpening": 40, "noiseReduction": 50, "colorNoiseReduction": 50]
                for key in ["texture", "clarity", "dehaze", "vignette"] { $0.global[key] = 0 }
            })
        XCTAssertEqual(try reset("crop"), expected { $0.crop = Crop() })
        XCTAssertEqual(try reset("all"), fresh)
    }

    func testResetWithoutASectionResetsEverything() throws {
        let defaults = PhotoDefaults(temperature: 4300, tint: 20)
        var state = try edited(EditingState(defaults: defaults)) { try $0.adjust(["exposureEV": 2, "temperature": 9000]) }
        try state.reset(defaults: defaults)
        XCTAssertEqual(state, EditingState(defaults: defaults))
        XCTAssertEqual(state.value("temperature"), 4300)
    }

    func testResetRejectsAnUnknownSection() throws {
        var state = try global(["exposureEV": 1])
        assertStateError(
            try state.reset(section: "everything", defaults: PhotoDefaults()),
            "reset section must be one of \"all\", \"light\", \"color\", \"curves\", \"hsl\", \"grading\", \"detail\", \"crop\", got \"everything\"")
        assertStateError(try state.reset(section: 3, defaults: PhotoDefaults()), contains: "reset section must be one of", "got 3")
        XCTAssertEqual(state.value("exposureEV"), 1)
    }

    // MARK: JSON

    func testJSONHasTheShapeScriptsAndTheModelSee() throws {
        let json = try richState().json
        XCTAssertEqual(Set(json.objectValue?.keys.map { $0 } ?? []), ["global", "curves", "hsl", "grading", "detail", "crop"])
        XCTAssertEqual(json["global"]?.objectValue?.count, 14)
        XCTAssertEqual(json["global"]?["temperature"], 4800)
        XCTAssertEqual(json["global"]?["exposureEV"], -0.35)
        XCTAssertEqual(json["curves"]?["rgb"], [[0, 0.03], [0.5, 0.5], [1, 0.98]])
        XCTAssertEqual(json["curves"]?["green"], [[0, 0], [1, 1]])
        XCTAssertEqual(json["hsl"]?.objectValue?.count, 8)
        XCTAssertEqual(json["hsl"]?["orange"], ["hue": 0, "saturation": 5, "luminance": 8])
        XCTAssertEqual(
            json["grading"],
            [
                "shadows": ["hue": 0, "saturation": 0, "luminance": 0],
                "midtones": ["hue": 0, "saturation": 0, "luminance": 0],
                "highlights": ["hue": 42, "saturation": 0.08, "luminance": 0],
                "blending": 0.5, "balance": -0.25,
            ])
        XCTAssertEqual(json["detail"], ["sharpening": 40, "noiseReduction": 25, "colorNoiseReduction": 0])
        XCTAssertEqual(
            json["crop"],
            ["x": 0, "y": 0.1, "width": 1, "height": 0.8, "angle": 2.5, "rotation": 90, "flipHorizontal": true, "flipVertical": false])
    }

    func testRoundTripsThroughJSON() throws {
        let state = try richState()
        XCTAssertEqual(try EditingState(json: state.json), state)
        XCTAssertEqual(try EditingState(json: EditingState().json), EditingState())
    }

    func testRoundTripsThroughJSONText() throws {
        let state = try richState()
        let parsed = try XCTUnwrap(JSONValue(text: state.json.text()))
        XCTAssertEqual(try EditingState(json: parsed), state)
        let pretty = try XCTUnwrap(JSONValue(text: state.json.text(pretty: true)))
        XCTAssertEqual(try EditingState(json: pretty), state)
    }

    func testCodableFormIsTheSameJSONAndRoundTrips() throws {
        let state = try richState()
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), state.json)
        XCTAssertEqual(try JSONDecoder().decode(EditingState.self, from: data), state)
    }

    func testInitFromJSONFillsInWhateverIsLeftOut() throws {
        XCTAssertEqual(try EditingState(json: [:]), EditingState())
        let partial = try EditingState(json: ["global": ["contrast": 20], "grading": ["balance": 0.5], "crop": ["rotation": 270]])
        XCTAssertEqual(
            partial,
            try edited {
                try $0.adjust(["contrast": 20])
                try $0.configureGrading(["balance": 0.5])
                try $0.setCrop(["rotation": 270])
            })
    }

    func testInitFromJSONRefusesDamagedDocuments() {
        assertStateError(try _ = EditingState(json: nil), "editing state must be an object")
        assertStateError(try _ = EditingState(json: [1, 2]), "editing state must be an object")
        assertStateError(try _ = EditingState(json: "state"), "editing state must be an object")
        assertStateError(try _ = EditingState(json: ["global": ["exposureEV": 99]]), "adjust.exposureEV must be between -5 and 5, got 99")
        assertStateError(try _ = EditingState(json: ["global": ["exposure": 1]]), contains: "adjust has no setting \"exposure\"")
        assertStateError(try _ = EditingState(json: ["global": nil]), "adjust must be an object, got null")
        assertStateError(try _ = EditingState(json: ["global": ["contrast": nil]]), contains: "adjust.contrast must be a finite number")
        assertStateError(try _ = EditingState(json: ["curves": ["luma": [[0, 0], [1, 1]]]]), contains: "curves has no setting \"luma\"", "rgb, red, green, blue")
        assertStateError(try _ = EditingState(json: ["curves": ["rgb": [[0, 0]]]]), "curves.rgb needs between 2 and 16 points, got 1")
        assertStateError(try _ = EditingState(json: ["curves": ["red": [[0, 0], [1, 2]]]]), "curves.red[1][1] must be between 0 and 1, got 2")
        assertStateError(try _ = EditingState(json: ["curves": []]), "curves must be an object, got an array")
        assertStateError(try _ = EditingState(json: ["hsl": ["teal": [:]]]), contains: "hsl has no setting \"teal\"")
        assertStateError(try _ = EditingState(json: ["hsl": ["red": ["hue": 500]]]), "hsl.red.hue must be between -100 and 100, got 500")
        assertStateError(try _ = EditingState(json: ["grading": ["shadows": ["saturation": 3]]]), "grading.shadows.saturation must be between 0 and 1, got 3")
        assertStateError(try _ = EditingState(json: ["grading": ["blending": 7]]), "grading.blending must be between 0 and 1, got 7")
        assertStateError(try _ = EditingState(json: ["grading": ["tones": [:]]]), contains: "grading has no setting \"tones\"", "shadows, midtones, highlights, blending, balance")
        assertStateError(try _ = EditingState(json: ["detail": ["sharpenRadius": 1]]), contains: "detail has no setting \"sharpenRadius\"")
        assertStateError(try _ = EditingState(json: ["crop": ["x": 0.5, "width": 0.8]]), contains: "crop rectangle leaves the frame")
        assertStateError(try _ = EditingState(json: ["crop": ["rotation": 45]]), contains: "crop.rotation must be 0, 90, 180 or 270")
    }

    // MARK: Changes

    func testChangesListsOneEntryPerSettingAndOnePerCurve() throws {
        let before = EditingState()
        let after = try edited(before) { state in
            try state.adjust(["exposureEV": 0.5])
            try state.setCurve(channel: "rgb", points: [[0, 0.05], [1, 1]])
            try state.adjustHSL(color: "blue", adjustments: ["saturation": -15])
        }
        XCTAssertEqual(
            after.changes(from: before),
            [
                EditingState.Change(path: "global.exposureEV", from: 0, to: 0.5),
                EditingState.Change(path: "curves.rgb", from: [[0, 0], [1, 1]], to: [[0, 0.05], [1, 1]]),
                EditingState.Change(path: "hsl.blue.saturation", from: 0, to: -15),
            ])
        XCTAssertEqual(before.changes(from: before), [])
        XCTAssertEqual(after.changes(from: after), [])
    }

    func testChangesComeSectionBySectionAndAlphabeticallyInside() throws {
        let before = EditingState()
        let after = try edited(before) { state in
            try state.setCrop(["flipHorizontal": true, "angle": 2, "rotation": 90])
            try state.setDetail(["sharpening": 30])
            try state.configureGrading(["balance": 0.4])
            try state.setGrading(range: "shadows", settings: ["hue": 220, "saturation": 0.1])
            try state.adjustHSL(color: "red", adjustments: ["luminance": 5])
            try state.adjustHSL(color: "aqua", adjustments: ["hue": -5])
            try state.setCurve(channel: "red", points: [[0, 0], [0.5, 0.6], [1, 1]])
            try state.setCurve(channel: "blue", points: [[0, 0.1], [1, 1]])
            try state.adjust(["vibrance": 10, "contrast": 5])
        }
        XCTAssertEqual(
            after.changes(from: before).map(\.path),
            [
                "global.contrast", "global.vibrance",
                "curves.blue", "curves.red",
                "hsl.aqua.hue", "hsl.red.luminance",
                "grading.balance", "grading.shadows.hue", "grading.shadows.saturation",
                "detail.sharpening",
                "crop.angle", "crop.flipHorizontal", "crop.rotation",
            ])
    }

    func testChangesReportTheOldAndNewValuesInBothDirections() throws {
        let before = try global(["contrast": 10])
        let after = try edited(before) {
            try $0.adjust(["contrast": 25])
            try $0.setCrop(["flipVertical": true])
        }
        XCTAssertEqual(
            after.changes(from: before),
            [.init(path: "global.contrast", from: 10, to: 25), .init(path: "crop.flipVertical", from: false, to: true)])
        XCTAssertEqual(
            before.changes(from: after),
            [.init(path: "global.contrast", from: 25, to: 10), .init(path: "crop.flipVertical", from: true, to: false)])
    }

    func testAChangeAsJSON() {
        let change = EditingState.Change(path: "curves.rgb", from: [[0, 0], [1, 1]], to: [[0, 0.05], [1, 1]])
        XCTAssertEqual(change.json, ["path": "curves.rgb", "from": [[0, 0], [1, 1]], "to": [[0, 0.05], [1, 1]]])
        XCTAssertEqual(change.json.text(), #"{"from":[[0,0],[1,1]],"path":"curves.rgb","to":[[0,0.05],[1,1]]}"#)
    }

    // MARK: Straightening

    func testStraightenScaleKnowsHowMuchFrameStraighteningCosts() {
        XCTAssertEqual(EditingState.straightenScale(angle: 0, aspect: 1.5), 1)
        XCTAssertEqual(EditingState.straightenScale(angle: 45, aspect: 1), 1 / 2.0.squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(EditingState.straightenScale(angle: 10, aspect: 1.5), EditingState.straightenScale(angle: -10, aspect: 1 / 1.5), accuracy: 1e-12)
        XCTAssertLessThan(EditingState.straightenScale(angle: 10, aspect: 1.5), EditingState.straightenScale(angle: 5, aspect: 1.5))
        // A longer frame loses more for the same angle.
        XCTAssertLessThan(EditingState.straightenScale(angle: 10, aspect: 3), EditingState.straightenScale(angle: 10, aspect: 1.5))
        for angle in stride(from: -45.0, through: 45, by: 2.5) {
            let scale = EditingState.straightenScale(angle: angle, aspect: 4.0 / 3)
            XCTAssertGreaterThan(scale, 0)
            XCTAssertLessThanOrEqual(scale, 1)
        }
    }
}
