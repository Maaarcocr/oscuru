import XCTest

/// The main flow, against a sample photo and a played-back model (-ui-testing): ask for an edit,
/// watch the assistant work and reply, open a version, save a filter, take a photo. Elements are
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
        sleep(1)
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

        // The camera, from the library: shoot, then go straight to the new photo's conversation.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(photo.waitForExistence(timeout: 30))
        capture("09-library")
        element(app, "library.camera").tap()
        let shutter = element(app, "camera.shutter")
        XCTAssertTrue(shutter.waitForExistence(timeout: 30))
        sleep(1)
        capture("10-camera")
        shutter.tap()
        let lastShot = element(app, "camera.lastShot")
        XCTAssertTrue(waitUntil(timeout: 60) { lastShot.exists && lastShot.isEnabled }, "the shot lands in the library")
        sleep(1)
        capture("11-camera-shot")
        lastShot.tap()
        XCTAssertTrue(element(app, "thread.original").waitForExistence(timeout: 30), "the shot opens as a new conversation")
        sleep(1)
        capture("12-camera-photo")

        // Settings.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(photo.waitForExistence(timeout: 30))
        element(app, "library.settings").tap()
        XCTAssertTrue(element(app, "settings.connected").waitForExistence(timeout: 30))
        capture("13-settings")

        // Signed out: one button to sign in, and the other ways on their own page.
        element(app, "settings.disconnect").tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 30))
        for label in ["Disconnect", "Scollega"] where alert.buttons[label].exists {
            alert.buttons[label].tap()
            break
        }
        XCTAssertTrue(element(app, "settings.signIn").waitForExistence(timeout: 30))
        capture("14-signed-out")
        element(app, "settings.other").tap()
        XCTAssertTrue(element(app, "settings.key").waitForExistence(timeout: 30))
        capture("15-other-ways")
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
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
