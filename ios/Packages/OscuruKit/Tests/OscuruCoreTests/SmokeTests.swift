import XCTest

@testable import OscuruCore

final class SmokeTests: XCTestCase {
    func testAnUntouchedPhotoNeedsNoTables() {
        let recipe = RenderRecipe(state: EditingState(), defaults: PhotoDefaults())
        XCTAssertTrue(recipe.toneTable.isEmpty)
        XCTAssertTrue(recipe.cube.isEmpty)
        XCTAssertNil(recipe.temperature)
    }
}
