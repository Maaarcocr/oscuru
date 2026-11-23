import Foundation
import XCTest

@testable import OscuruCore

final class RenderRecipeTests: XCTestCase {
    private let rawDefaults = PhotoDefaults(temperature: 5200, tint: 10, sharpening: 40, noiseReduction: 50, colorNoiseReduction: 50)

    func testAnUntouchedPhotoSendsNothing() {
        let recipe = RenderRecipe(state: EditingState(defaults: rawDefaults), defaults: rawDefaults)
        XCTAssertEqual(recipe.exposureEV, 0)
        XCTAssertNil(recipe.temperature, "white balance stays as shot")
        XCTAssertNil(recipe.tint)
        XCTAssertEqual(recipe.shadowAmount, 0)
        XCTAssertEqual(recipe.highlightAmount, 1)
        XCTAssertEqual(recipe.localContrast, [])
        XCTAssertNil(recipe.sharpening, "the decoder's own default is left alone")
        XCTAssertNil(recipe.noiseReduction)
        XCTAssertNil(recipe.colorNoiseReduction)
        XCTAssertEqual(recipe.vignette, 0)
        XCTAssertEqual(recipe.vignette.sign, .plus, "vignette must be 0, not −0")
        XCTAssertEqual(recipe.rotation, 0)
        XCTAssertFalse(recipe.flipHorizontal)
        XCTAssertFalse(recipe.flipVertical)
        XCTAssertEqual(recipe.angle, 0)
        XCTAssertEqual(recipe.cropX, 0)
        XCTAssertEqual(recipe.cropY, 0)
        XCTAssertEqual(recipe.cropWidth, 1)
        XCTAssertEqual(recipe.cropHeight, 1)
        XCTAssertTrue(recipe.toneTable.isEmpty)
        XCTAssertTrue(recipe.cube.isEmpty)
        XCTAssertEqual(recipe.toneTableSize, 0)
        XCTAssertEqual(recipe.cubeSize, 0)
        XCTAssertEqual(recipe, RenderRecipe(), "the same as a recipe that does nothing")
    }

    func testAnUntouchedPhotoWithGenericDefaultsAlsoSendsNothing() {
        XCTAssertEqual(RenderRecipe(state: EditingState(), defaults: PhotoDefaults()), RenderRecipe())
    }

    func testMapsSettingsToFilterAmounts() throws {
        let defaults = PhotoDefaults(temperature: 5200, tint: 10)
        let state = try edited(EditingState(defaults: defaults)) { state in
            try state.adjust([
                "exposureEV": 0.5, "temperature": 6000, "highlights": -100, "shadows": 50, "clarity": 50, "texture": -50, "vignette": -40,
                "contrast": 10, "saturation": 10,
            ])
            try state.setDetail(["sharpening": 30, "noiseReduction": 20])
            try state.setCrop(["x": 0.1, "y": 0.2, "width": 0.5, "height": 0.6, "angle": 3, "rotation": 270, "flipVertical": true])
        }
        let recipe = RenderRecipe(state: state, defaults: defaults)
        XCTAssertEqual(recipe.exposureEV, 0.5)
        XCTAssertEqual(recipe.temperature, 6000)
        XCTAssertEqual(recipe.tint, 10, "tint travels with temperature once either has changed")
        XCTAssertEqual(recipe.highlightAmount, 0.3, accuracy: 5e-7)
        XCTAssertEqual(recipe.shadowAmount, 0.4, accuracy: 5e-7)
        XCTAssertEqual(recipe.localContrast.count, 2)
        XCTAssertEqual(recipe.localContrast.first?.radius, 0.02)
        XCTAssertEqual(recipe.localContrast.first?.intensity ?? 0, 0.35, accuracy: 1e-12)
        XCTAssertEqual(recipe.localContrast.last?.radius, 0.003)
        XCTAssertEqual(recipe.localContrast.last?.intensity ?? 0, -0.3, accuracy: 1e-12)
        XCTAssertEqual(recipe.sharpening, 0.3)
        XCTAssertEqual(recipe.noiseReduction, 0.2)
        XCTAssertNil(recipe.colorNoiseReduction)
        XCTAssertEqual(recipe.vignette, 0.4, "a negative vignette setting darkens the corners")
        XCTAssertEqual(recipe.cropX, 0.1)
        XCTAssertEqual(recipe.cropY, 0.2)
        XCTAssertEqual(recipe.cropWidth, 0.5)
        XCTAssertEqual(recipe.cropHeight, 0.6)
        XCTAssertEqual(recipe.angle, 3)
        XCTAssertEqual(recipe.rotation, 270)
        XCTAssertTrue(recipe.flipVertical)
        XCTAssertFalse(recipe.flipHorizontal)
    }

    func testWhiteBalanceIsSentWhenEitherPartLeavesTheAsShotValue() throws {
        let defaults = PhotoDefaults(temperature: 5200, tint: 10)
        let tinted = RenderRecipe(state: try edited(EditingState(defaults: defaults)) { try $0.adjust(["tint": 14]) }, defaults: defaults)
        XCTAssertEqual(tinted.temperature, 5200)
        XCTAssertEqual(tinted.tint, 14)

        let restored = try edited(EditingState(defaults: defaults)) {
            try $0.adjust(["temperature": 6000])
            try $0.adjust(["temperature": 5200])
        }
        XCTAssertNil(RenderRecipe(state: restored, defaults: defaults).temperature)
        XCTAssertNil(RenderRecipe(state: restored, defaults: defaults).tint)
    }

    func testAsShotIsJudgedAgainstTheRoundedPhotoDefaults() {
        // The state starts at the rounded as-shot value, so an untouched photo must still count as untouched.
        let defaults = PhotoDefaults(temperature: 5234.6, tint: 11.2, sharpening: 39.6)
        let recipe = RenderRecipe(state: EditingState(defaults: defaults), defaults: defaults)
        XCTAssertNil(recipe.temperature)
        XCTAssertNil(recipe.tint)
        XCTAssertNil(recipe.sharpening)
    }

    func testHighlightsAndShadowsOnlyGoToTheLocalFiltersInTheirRecoveringDirection() throws {
        let recovering = RenderRecipe(state: try global(["highlights": -50, "shadows": 100]), defaults: PhotoDefaults())
        XCTAssertEqual(recovering.highlightAmount, 0.65, accuracy: 1e-12)
        XCTAssertEqual(recovering.shadowAmount, 0.8, accuracy: 1e-12)
        XCTAssertTrue(recovering.toneTable.isEmpty, "the recovering directions need no tone table")

        let other = RenderRecipe(state: try global(["highlights": 50, "shadows": -100]), defaults: PhotoDefaults())
        XCTAssertEqual(other.highlightAmount, 1)
        XCTAssertEqual(other.shadowAmount, 0)
        XCTAssertFalse(other.toneTable.isEmpty, "the other directions are point operations")
    }

    func testClarityAndTextureBecomeLocalContrastPassesClarityFirst() throws {
        let clarity = RenderRecipe(state: try global(["clarity": -100]), defaults: PhotoDefaults())
        XCTAssertEqual(clarity.localContrast, [.init(radius: 0.02, intensity: -0.7)])
        let texture = RenderRecipe(state: try global(["texture": 100]), defaults: PhotoDefaults())
        XCTAssertEqual(texture.localContrast, [.init(radius: 0.003, intensity: 0.6)])
        let both = RenderRecipe(state: try global(["texture": 100, "clarity": 100]), defaults: PhotoDefaults())
        XCTAssertEqual(both.localContrast.map(\.radius), [0.02, 0.003])
    }

    func testDetailIsSentOnlyWhereItDiffersFromTheDecoderDefault() throws {
        let state = try edited(EditingState(defaults: rawDefaults)) { try $0.setDetail(["sharpening": 0, "colorNoiseReduction": 100, "noiseReduction": 50]) }
        let recipe = RenderRecipe(state: state, defaults: rawDefaults)
        XCTAssertEqual(recipe.sharpening, 0)
        XCTAssertNil(recipe.noiseReduction)
        XCTAssertEqual(recipe.colorNoiseReduction, 1)
    }

    func testAPositiveVignetteLightensTheCorners() throws {
        XCTAssertEqual(RenderRecipe(state: try global(["vignette": 100]), defaults: PhotoDefaults()).vignette, -1)
        XCTAssertEqual(RenderRecipe(state: try global(["vignette": -100]), defaults: PhotoDefaults()).vignette, 1)
    }

    func testTablesAreTheFloatsAsBytes() throws {
        let state = try edited(try global(["contrast": 10, "saturation": 10])) { try $0.setCurve(channel: "red", points: [[0, 0], [0.5, 0.6], [1, 1]]) }
        let recipe = RenderRecipe(state: state, defaults: PhotoDefaults())
        XCTAssertEqual(recipe.toneTableSize, 1024)
        XCTAssertEqual(recipe.cubeSize, 33)
        XCTAssertEqual(recipe.toneTable.count, recipe.toneTableSize * 3 * 4)
        XCTAssertEqual(recipe.toneTable.count, 12288)
        XCTAssertEqual(recipe.cube.count, recipe.cubeSize * recipe.cubeSize * recipe.cubeSize * 4 * 4)
        XCTAssertEqual(recipe.cube.count, 574_992)

        let tone = floats(in: recipe.toneTable)
        XCTAssertEqual(tone.first, 0)
        XCTAssertEqual(tone.last, 1)
        XCTAssertEqual(tone, ColorPipeline.toneTables(state))
        XCTAssertEqual(floats(in: recipe.cube), ColorPipeline.colorCube(state))
    }

    func testOnlyTheStageThatIsNeededIsSent() throws {
        let toneOnly = RenderRecipe(state: try global(["contrast": 10]), defaults: PhotoDefaults())
        XCTAssertEqual(toneOnly.toneTableSize, 1024)
        XCTAssertFalse(toneOnly.toneTable.isEmpty)
        XCTAssertEqual(toneOnly.cubeSize, 0)
        XCTAssertTrue(toneOnly.cube.isEmpty)

        let colourOnly = RenderRecipe(state: try global(["vibrance": 10]), defaults: PhotoDefaults())
        XCTAssertEqual(colourOnly.toneTableSize, 0)
        XCTAssertTrue(colourOnly.toneTable.isEmpty)
        XCTAssertEqual(colourOnly.cubeSize, 33)
        XCTAssertFalse(colourOnly.cube.isEmpty)
    }

    func testEqualStatesGiveEqualRecipes() throws {
        let state = try global(["contrast": 10, "saturation": 10, "clarity": 5])
        XCTAssertEqual(RenderRecipe(state: state, defaults: PhotoDefaults()), RenderRecipe(state: state, defaults: PhotoDefaults()))
        XCTAssertNotEqual(RenderRecipe(state: state, defaults: PhotoDefaults()), RenderRecipe(state: try global(["contrast": 11, "saturation": 10, "clarity": 5]), defaults: PhotoDefaults()))
    }
}
