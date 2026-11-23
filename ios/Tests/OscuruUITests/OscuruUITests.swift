import XCTest

/// The main flow, against a sample photo and a played-back model (-ui-testing): ask for an edit,
/// watch the assistant work, compare, save a filter, revert, look at the conversation. Elements are
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

        // The editor: the photo and a place to say what you want.
        let prompt = element(app, "photo.prompt")
        XCTAssertTrue(prompt.waitForExistence(timeout: 30))
        XCTAssertTrue(element(app, "photo.image").waitForExistence(timeout: 30))
        capture("02-photo")
        XCTAssertFalse(element(app, "photo.undo").isEnabled, "nothing to undo on an untouched photo")

        // An instruction. The assistant runs scripts on the phone until it is happy, then says what it did.
        prompt.tap()
        prompt.typeText("Make it cinematic and recover the sky")
        capture("03-typing")
        element(app, "photo.send").tap()
        XCTAssertTrue(element(app, "photo.stop").waitForExistence(timeout: 30), "the assistant can be stopped while it works")
        capture("04-working")
        let note = element(app, "photo.note")
        XCTAssertTrue(note.waitForExistence(timeout: 120), "the assistant finishes with a note")
        capture("05-edited")
        XCTAssertTrue(element(app, "photo.undo").isEnabled, "its edits are undo steps")

        // Touch and hold shows the original.
        element(app, "photo.image").press(forDuration: 1.2)

        // Save the look as a filter.
        element(app, "photo.more").tap()
        let filters = element(app, "photo.filters")
        XCTAssertTrue(filters.waitForExistence(timeout: 30))
        capture("06-menu")
        filters.tap()
        let name = element(app, "filters.name")
        XCTAssertTrue(name.waitForExistence(timeout: 30))
        name.tap()
        name.typeText("Dusk")
        element(app, "filters.save").tap()
        let saved = element(app, "filters.item")
        XCTAssertTrue(saved.waitForExistence(timeout: 30), "the filter is saved")
        capture("07-filters")
        element(app, "filters.done").tap()

        // Take the assistant's edits back, then apply the filter instead: the same look returns.
        let revert = element(app, "photo.revert")
        XCTAssertTrue(revert.waitForExistence(timeout: 30))
        revert.tap()
        XCTAssertTrue(revert.waitForNonExistence(timeout: 30), "nothing left to revert")
        capture("08-reverted")
        element(app, "photo.more").tap()
        XCTAssertTrue(filters.waitForExistence(timeout: 30))
        filters.tap()
        XCTAssertTrue(saved.waitForExistence(timeout: 30))
        saved.tap()
        XCTAssertTrue(saved.waitForNonExistence(timeout: 30), "applying a filter closes the sheet")
        capture("09-filter-applied")

        // The conversation, with the scripts the assistant ran.
        note.tap()
        let script = element(app, "conversation.script")
        XCTAssertTrue(script.waitForExistence(timeout: 30))
        script.tap()
        capture("10-conversation")
        element(app, "conversation.done").tap()

        // A second instruction in the same conversation: the assistant saves a filter itself.
        prompt.tap()
        prompt.typeText("Save this look as a filter")
        element(app, "photo.send").tap()
        XCTAssertTrue(element(app, "photo.stop").waitForNonExistence(timeout: 120))
        XCTAssertTrue(note.waitForExistence(timeout: 30))
        capture("11-second-instruction")

        // Back to the library; settings show the connection and what has been spent.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(photo.waitForExistence(timeout: 30))
        element(app, "library.settings").tap()
        XCTAssertTrue(element(app, "settings.connected").waitForExistence(timeout: 30))
        capture("12-settings")
        element(app, "settings.done").tap()
        capture("13-library-after")
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
