import XCTest

/// The main flow, against a sample photo and a played-back model (-ui-testing): ask for an edit,
/// watch the assistant work and reply, open a version, save a filter. Elements are
/// found by accessibility identifier, never by text, so the same test runs in English and Italian.
/// Screenshots are kept in the result bundle and exported by CI, which is how the app is reviewed
/// without a Mac.
final class OscuruUITests: XCTestCase {
    @MainActor
    func testEditingAPhotoWithTheAssistant() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        // The library, with the sample photo.
        let photo = element(app, "library.photo")
        XCTAssertTrue(photo.waitForExistence(timeout: 60))
        capture("01-library")
        photo.tap()

        // The thread: the original, and a place to say what you want.
        let field = element(app, "composer.field")
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        XCTAssertTrue(element(app, "thread.original").waitForExistence(timeout: 30))
        capture("02-photo")

        // An instruction. The assistant works, the photo changes, then it replies in the thread.
        field.tap()
        field.typeText("Make it cinematic and recover the sky")
        capture("03-typing")
        element(app, "composer.send").tap()
        XCTAssertTrue(element(app, "composer.stop").waitForExistence(timeout: 30))
        capture("04-working")
        XCTAssertTrue(element(app, "thread.reply").waitForExistence(timeout: 120), "the assistant replies")
        capture("05-reply")
        element(app, "thread.steps").tap()
        capture("06-steps")

        // A version full screen.
        element(app, "thread.version").tap()
        XCTAssertTrue(element(app, "viewer.close").waitForExistence(timeout: 30))
        capture("07-viewer")
        element(app, "viewer.close").tap()

        // Save the look as a filter.
        element(app, "photo.menu").tap()
        element(app, "menu.filters").tap()
        let name = element(app, "filters.name")
        XCTAssertTrue(name.waitForExistence(timeout: 30))
        name.tap()
        name.typeText("Dusk")
        element(app, "filters.save").tap()
        XCTAssertTrue(element(app, "filters.item").waitForExistence(timeout: 30), "the filter is saved")
        capture("08-filters")
        element(app, "filters.done").tap()

        // Settings.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(photo.waitForExistence(timeout: 30))
        element(app, "library.settings").tap()
        XCTAssertTrue(element(app, "settings.connected").waitForExistence(timeout: 30))
        capture("09-settings")
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
